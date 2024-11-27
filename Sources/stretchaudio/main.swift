//
//  AudioEngine-Stretch-Audio
//
//  Source: RecordKit - https://nonstrict.eu/recordkit/
//
//  Created by Tom Lokhorst on 2024-07-24.
//

import AVFoundation

do {
    // Parse commandline arguments
    let args = ProcessInfo.processInfo.arguments
    guard args.count == 4, let extraMilliseconds = Int64(args[3]) else {
        print("USAGE: stretchaudio inputfile.m4a outputfile.m4a [extraMilliseconds]")
        exit(EXIT_SUCCESS)
    }
    let inputURL = URL(fileURLWithPath: args[1])
    let outputURL = URL(fileURLWithPath: args[2])
    let extraTime = CMTime(value: extraMilliseconds, timescale: 1000)

    // Compute target duration
    let inputFile = try AVAudioFile(forReading: inputURL)
    let inputDuration = CMTime(value: inputFile.length, timescale: CMTimeScale(inputFile.processingFormat.sampleRate))
    let targetDuration = inputDuration + extraTime

    // Stretch the audio file
    do {
        try stretchAudioFile(inputURL: inputURL, to: targetDuration, outputURL: outputURL)
        print("Stretched audio written to", args[2])
    } catch let error as NSError {
        print("Error stretching audio", error.debugDescription)
    }
}


func stretchAudioFile(inputURL: URL, to targetDuration: CMTime, outputURL: URL) throws {
    let sourceFile = try AVAudioFile(forReading: inputURL)

    let inputFileLength = sourceFile.length
    let format = sourceFile.processingFormat

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()

    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)

    player.scheduleFile(sourceFile, at: nil)

    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)

    try engine.start()
    player.play()

    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!

    let outputFile = try AVAudioFile(forWriting: outputURL, settings: sourceFile.fileFormat.settings)
    let outputFileLength: AVAudioFramePosition = AVAudioFramePosition(targetDuration.seconds * format.sampleRate)

    if outputFileLength <= inputFileLength {
        fatalError("Can only stretch to longer duration.")
    }

    // Compute step size for render loop
    let neededExtraFrames = outputFileLength - inputFileLength
    let idealStride = inputFileLength / neededExtraFrames
    let insertStride = AVAudioFrameCount(max(512, min(engine.manualRenderingMaximumFrameCount, AVAudioFrameCount(idealStride))))

    // Keep track of how much we have already inserted
    var extraInserted: AVAudioFrameCount = 0

    while engine.manualRenderingSampleTime < inputFileLength {
        let frameCount = inputFileLength - engine.manualRenderingSampleTime
        let framesToRender = min(AVAudioFrameCount(frameCount), insertStride)

        let status = try engine.renderOffline(framesToRender, to: buffer)
        let inputPosition = engine.manualRenderingSampleTime

        switch status {
        case .success:
            let position = Double(inputPosition) / Double(inputFileLength)
            let outputPosition = AVAudioFramePosition(Double(outputFileLength) * position)

            let needed = AVAudioFrameCount(outputPosition - inputPosition)
            let duplicateLength: AVAudioFrameCount = needed - extraInserted

            let orig = buffer.frameLength

            // Write short prefix of buffer
            buffer.frameLength = duplicateLength
            try outputFile.write(from: buffer)

            extraInserted += duplicateLength

            // Write original buffer
            buffer.frameLength = orig
            try outputFile.write(from: buffer)

        case .insufficientDataFromInputNode:
            // Applicable only when using the input node as one of the sources.
            break

        case .cannotDoInCurrentContext:
            // The engine couldn't render in the current render call.
            // Retry in the next iteration.
            break

        case .error:
            // An error occurred while rendering the audio.
            fatalError("The manual rendering failed.")

        @unknown default:
            fatalError("Audio engine reported an unknown state while rendering offline: \(status.rawValue)")
        }
    }

    player.stop()
    engine.stop()
}
