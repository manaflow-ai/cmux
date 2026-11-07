import AVFoundation
import CoreGraphics
import Foundation

/// A generated H.264 clip for the tests that need a playable video file (the video wallpaper's).
nonisolated enum TestVideoClip {
    /// An H.264 video: a bar sweeping over a gradient, 30 frames per second.
    static func writeVideo(to url: URL, width: Int, height: Int, frames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let job = TestVideoClipJob(writer: writer, input: input, adaptor: adaptor, width: width, height: height, frames: frames)
        await job.run()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

/// Feeds frames when the writer asks for them (no polling), then finishes.
// crash-allow: test helper only; after run() starts, the writer's own serial queue is the only thread that touches this state
nonisolated final class TestVideoClipJob: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int, frames: Int
    private var next = 0
    private var finished = false
    private let queue = DispatchQueue(label: "cmux.test.video-clip")

    init(writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
         width: Int, height: Int, frames: Int) {
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.width = width
        self.height = height
        self.frames = frames
    }

    func run() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                // The requester may call once more after the input is marked finished; resume once.
                guard !finished else { return }
                // A writer that failed (its encoder went away, say) takes no more frames and will
                // not ask again: stop feeding it, so no frame comes from its torn-down pool.
                while writer.status == .writing, input.isReadyForMoreMediaData, next < frames {
                    if let buffer = frame(next),
                       !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(next), timescale: 30)) { break }
                    next += 1
                }
                if writer.status == .writing, next < frames { return }
                finished = true
                guard writer.status == .writing else { return done.resume() }
                input.markAsFinished()
                writer.finishWriting { done.resume() }
            }
        }
    }

    private func frame(_ i: Int) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return buffer }
        let t = CGFloat(i) / CGFloat(max(1, frames - 1))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3 + 0.3 * t, blue: 0.45, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.8, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: t * CGFloat(width - 80), y: CGFloat(height) * 0.35, width: 80, height: CGFloat(height) * 0.3))
        return buffer
    }
}
