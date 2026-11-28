import AVFoundation
import CmuxHomeCore
import CoreGraphics
import Foundation
import ImageIO
@testable import CmuxHomeRender

/// Attachment refs and a fake loader: no backend, no network. The loader
/// writes small PNG files on demand and can hold a request until the test
/// releases it (bytes that arrive late).
@MainActor
enum AttachmentFixtures {
    static let photo = AttachmentRef(hash: "sha256-photo", name: "beach.jpg", mimeType: "image/jpeg", byteCount: 2_400_000,
                                     width: 1200, height: 900)
    static let video = AttachmentRef(hash: "sha256-video", name: "demo.mov", mimeType: "video/quicktime", byteCount: 9_800_000,
                                     width: 1920, height: 1080)
    static let tall = AttachmentRef(hash: "sha256-tall", name: "screen.png", mimeType: "image/png", byteCount: 400_000,
                                    width: 600, height: 2000)
    static let pdf = AttachmentRef(hash: "sha256-pdf", name: "report.pdf", mimeType: "application/pdf", byteCount: 1_234_567)
    /// An image without a pixel size cannot be laid out before its bytes: it shows as a file.
    static let unsizedImage = AttachmentRef(hash: "sha256-unsized", name: "scan.heic", mimeType: "image/heic", byteCount: 800_000)

    static func message(_ seq: Seq, _ author: ParticipantID, _ parts: [MessagePart]) -> Message {
        Message(id: MessageID("msg_\(seq)"), conversation: Fixtures.conversation, seq: seq, clientMessageID: IdempotencyKey("key_\(seq)"),
                author: author, parts: parts, createdAt: Fixtures.start.addingTimeInterval(Double(seq) * 30))
    }

    /// A PNG of `size` pixels in one colour, written to a temporary file.
    nonisolated static func png(width: Int, height: Int, gray: CGFloat) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-attach-\(UUID().uuidString).png")
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError.draw }
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray * 0.8, blue: gray * 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw FixtureError.draw }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FixtureError.draw }
        return url
    }

    enum FixtureError: Error { case draw, held }
}

/// Answers thumbnails with generated PNGs and originals with a file URL.
/// `hold()` makes every request wait until `release()`.
actor FakeAttachmentLoader: HomeAttachmentLoader {
    private(set) var thumbnailRequests: [String] = []
    private(set) var originalRequests: [String] = []
    private(set) var posterRequests: [String] = []
    /// Videos without a poster (the owner answers attachment.no_poster).
    var noPoster = false
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func hold() { held = true }

    func release() {
        held = false
        let w = waiting
        waiting = []
        for c in w { c.resume() }
    }

    private func gate() async {
        guard held else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func thumbnail(for ref: AttachmentRef, maxPixel: Int) async throws -> URL {
        thumbnailRequests.append(ref.hash)
        await gate()
        return try AttachmentFixtures.png(width: 64, height: 48, gray: 0.7)
    }

    func setNoPoster() { noPoster = true }

    func poster(for ref: AttachmentRef, maxPixel: Int) async throws -> URL {
        posterRequests.append(ref.hash)
        await gate()
        if noPoster { throw AttachmentFixtures.FixtureError.held }
        return try AttachmentFixtures.png(width: 64, height: 36, gray: 0.4)
    }

    func original(for ref: AttachmentRef) async throws -> URL {
        originalRequests.append(ref.hash)
        await gate()
        return try await TestVideo.url()
    }
}

/// A real four-frame H.264 file, so the player item loads (a missing file
/// would fail and trigger the expired-URL refetch).
@MainActor
enum TestVideo {
    private static var made: URL?

    static func url() async throws -> URL {
        if let made { return made }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-attach-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 36,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<4 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
            if let buffer { adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        made = url
        return url
    }
}
