#if DEBUG || CMUX_BENCH_HOOKS
import AVFoundation
import CoreMedia
import Foundation

/// The movie writer of a `debug.motion record_*` recording (``ScreenRecording``), apart from the capture, so its file
/// format (a fragmented QuickTime movie: a recording cut off before `finishWriting` still plays) has its own test
/// (MotionScreenRecordMovieTests).
nonisolated extension ScreenRecording {
    /// A movie writer for frames of `width` x `height` at `url`, writing, its session started at time zero, with its
    /// one video input (real time) and that input's pixel buffer adaptor: HEVC at `bitsPerSecond`, or ProRes 4444.
    static func movieWriter(url: URL, width: Int, height: Int, prores: Bool, bitsPerSecond: Int) throws
        -> (writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        var settings: [String: Any] = [AVVideoWidthKey: width, AVVideoHeightKey: height]
        if prores {
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        } else {
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitsPerSecond, AVVideoExpectedSourceFrameRateKey: 120,
                AVVideoMaxKeyFrameIntervalKey: 120, AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any]
        }
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) } catch {
            throw Failure(description: "movie writer: \(error)")
        }
        // A fragmented movie: the header first, then a fragment each half second, so a movie that is never stopped
        // (a kit that fetched it mid-film, a quit, a crash) plays up to its last fragment. Unfragmented, its index is
        // written only by finishWriting, and a cut-off movie has none: no moov atom, no frame a reader can open (20
        // gallery films, cmux-ad m29 item 3).
        writer.movieFragmentInterval = CMTime(value: 1, timescale: 2)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Failure(description: "movie writer refused the input (\(width)x\(height))") }
        writer.add(input)
        // The adaptor must exist before startWriting: AVFoundation raises an Objective-C exception for an adaptor
        // made on an input that already started, and the process aborts (cmux18 and cmux24, 2026-11-02 02:15Z).
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else {
            throw Failure(description: "movie writer did not start: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)
        return (writer, input, adaptor)
    }
}
#endif
