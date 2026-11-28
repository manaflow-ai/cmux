#if DEBUG
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// DEBUG ONLY. Sample attachments for the native fixture, generated on the
/// spot: a photo, a two-second video and a one-page PDF. The fixture's
/// `HomeStore` prepares and sends them through the mock owner.
nonisolated enum HomeFixtureMedia {
    /// A generated photo, a two-second video and a one-page PDF in a fresh temporary folder.
    static func make() async throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-home-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("Harbor at dusk.png")
        try writePNG(width: 1200, height: 900, to: photo, hue: 0.08)
        let video = dir.appendingPathComponent("Build replay.mp4")
        try await writeVideo(to: video, width: 640, height: 360, frames: 60)
        let pdf = dir.appendingPathComponent("Quarterly review.pdf")
        try writePDF(to: pdf)
        return [photo, video, pdf]
    }

    static func writePNG(width: Int, height: Int, to url: URL, hue: CGFloat) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        let colors = [CGColor(srgbRed: 0.95, green: 0.55 + hue, blue: 0.3, alpha: 1), CGColor(srgbRed: 0.2, green: 0.25, blue: 0.5, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: CGFloat(width) * 0.6, y: CGFloat(height) * 0.45, width: CGFloat(width) * 0.16, height: CGFloat(width) * 0.16))
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.1, blue: 0.18, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * 0.3))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func writePDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 72, y: 680, width: 300, height: 24))
        ctx.endPDFPage()
        ctx.closePDF()
    }

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
        let job = VideoJob(writer: writer, input: input, adaptor: adaptor, width: width, height: height, frames: frames)
        await job.run()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

/// Feeds frames when the writer asks for them (no polling), then finishes.
// crash-allow: DEBUG fixture only; after run() starts, the writer's own serial queue is the only thread that touches this state
nonisolated final class VideoJob: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int, frames: Int
    private var next = 0
    private let queue = DispatchQueue(label: "cmux.home.fixture.video")

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
                while input.isReadyForMoreMediaData, next < frames {
                    if let buffer = frame(next) {
                        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(next), timescale: 30))
                    }
                    next += 1
                }
                guard next >= frames else { return }
                next = .max
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

#endif
