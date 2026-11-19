import AVFoundation
import CmuxHomeCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Pictures and videos in the transcript (user 2026-11-16, "in chief imessage, image/video previews lowkey kinda messy",
/// with a Chief message of one PNG and two MP4s and a sent picture of mine):
/// - a video whose owner stores no poster (every video the Chief attaches) was a blank gray box: it shows its first
///   frame, at the frame's aspect;
/// - the pictures and videos of one message stacked at different widths (300 pt over 240 pt): one width;
/// - a save glyph sat beside every picture, at another x per width, and took no click: nothing is drawn beside them;
/// - a picture whose load failed once (the owner not connected yet after a relaunch) stayed an empty gray box for the
///   life of the process: it loads on a later try.
@MainActor @Suite struct HomeMediaPreviewTests {
    static let chief = ParticipantID("agent_chief")
    static let me = ParticipantID("user_me")
    static let id = ConversationID("conv_media")

    // MARK: Fixtures

    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("home-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A solid PNG of `width` x `height` px.
    static func png(_ width: Int, _ height: Int, in dir: URL, name: String = "pic.png") throws -> URL {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let url = dir.appendingPathComponent(name)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// A short H.264 movie of `width` x `height` px, solid red frames, and no poster anywhere.
    static func movie(_ width: Int, _ height: Int, in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("clip.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height { for x in 0..<width { let i = y * row + x * 4; base[i] = 0; base[i + 1] = 0; base[i + 2] = 230; base[i + 3] = 255 } }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    static func pixelSize(_ asset: String) -> CGSize? {
        guard let url = URL(string: asset), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Counts calls and answers with `answer` (a URL, or a throw).
    final class Fetcher: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(String, AttachmentVariant)] = []
        let answer: @Sendable (Int, AttachmentVariant) throws -> URL
        init(_ answer: @escaping @Sendable (Int, AttachmentVariant) throws -> URL) { self.answer = answer }
        var fetch: HomeMedia.Fetch {
            { [self] ref, variant in
                let n = lock.withLock { calls.append((ref.hash, variant)); return calls.count }
                return try answer(n, variant)
            }
        }
        var count: Int { lock.withLock { calls.count } }
    }

    // MARK: Videos without a poster

    /// The Chief's MP4s have no poster: the bubble shows the video's first frame, not a blank box.
    @Test func aVideoWithoutAPosterShowsItsFirstFrame() async throws {
        let dir = try Self.folder()
        let clip = try await Self.movie(320, 180, in: dir)
        let fetcher = Fetcher { _, variant in
            switch variant {
            case .original: return clip
            default: throw HomeRejection.invalid("no_poster")
            }
        }
        let media = HomeMedia()
        media.fetch = fetcher.fetch
        let size = (try FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? Int) ?? 1
        let ref = AttachmentRef(hash: "video-\(UUID().uuidString)", name: "after-slow4x.mp4", mimeType: "video/mp4", byteCount: size)
        media.request(ref)
        await media.settled()
        let asset = try #require(media.asset(ref.hash), "a video without a poster kept no picture (the blank gray box)")
        #expect(asset != "cmux-home-media:unavailable")
        let px = try #require(Self.pixelSize(asset))
        #expect(abs(px.width / px.height - 16.0 / 9.0) < 0.02, "the frame keeps the video's aspect: \(px)")
    }

    // MARK: A picture whose first load failed

    /// The first fetch fails (the owner not connected yet after a relaunch); the picture still arrives.
    @Test func aPictureWhoseFirstLoadFailedLoadsLater() async throws {
        let dir = try Self.folder()
        let picture = try Self.png(2256, 454, in: dir)
        let fetcher = Fetcher { call, _ in
            if call == 1 { throw HomeRejection.invalid("attachment_not_loaded") }
            return picture
        }
        let media = HomeMedia()
        media.fetch = fetcher.fetch
        let ref = AttachmentRef(hash: "pic-\(UUID().uuidString)", name: "CleanShot.png", mimeType: "image/png",
                                byteCount: 107_824, width: 2256, height: 454)
        media.request(ref)
        await media.settled()
        // A later refresh asks again (HomeProjection.refreshAttachments requests every shown part).
        media.request(ref)
        await media.settled()
        let asset = try #require(media.asset(ref.hash), "one failed load left the picture an empty gray box")
        #expect(asset != "cmux-home-media:unavailable")
        #expect(fetcher.count >= 2)
    }

    // MARK: Layout

    static func summary() -> ConversationSummary {
        ConversationSummary(id: id, participants: [
            CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
            CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
        ], lastSeq: 1, createdAt: Replay.base, updatedAt: Replay.base)
    }

    /// The rows of one message from `author` with `parts`, pictures from `pictures` (hash to `file:` asset).
    static func rows(_ parts: [MessagePart], author: ParticipantID = chief, pictures: [String: String] = [:]) -> [RowSpec] {
        var core = ProjectionCore(me: me)
        core.media = { pictures[$0] }
        let item = TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: author, parts: parts,
                                  createdAt: Replay.base.addingTimeInterval(2), delivery: .committed, messageID: MessageID("msg_1"))
        let (conv, _) = core.install(id, items: [item], summary: summary())
        return RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: Replay.base.addingTimeInterval(60))
    }

    static func mediaRows(_ rows: [RowSpec]) -> [(spec: RowSpec, row: PartRow, a: MessagesLabHome.Attachment)] {
        rows.compactMap { spec in
            guard case let .part(p) = spec.kind, case let .attachment(a) = p.part, a.kind == "image" || a.kind == "video" else { return nil }
            return (spec, p, a)
        }
    }

    /// The Chief's message of 36844: words, a wide PNG and two MP4s without a pixel size. Its pictures and videos are
    /// one column of one width, each at its own aspect.
    @Test(arguments: [Self.chief, Self.me])
    func thePicturesAndVideosOfOneMessageShareOneWidth(author: ParticipantID) throws {
        let dir = try Self.folder()
        let shot = try Self.png(1760, 880, in: dir, name: "shot.png")
        let frame = try Self.png(1280, 720, in: dir, name: "frame.png")
        let parts: [MessagePart] = [
            .text("Mouseup fade 100%"),
            .attachment(AttachmentRef(hash: "img", name: "compare-exit-frames.png", mimeType: "image/png", byteCount: 106_662,
                                      width: 1760, height: 880)),
            .attachment(AttachmentRef(hash: "v1", name: "before-slow4x.mp4", mimeType: "video/mp4", byteCount: 416_515)),
            .attachment(AttachmentRef(hash: "v2", name: "after-slow4x.mp4", mimeType: "video/mp4", byteCount: 457_588)),
        ]
        let media = Self.mediaRows(Self.rows(parts, author: author, pictures: [
            "img": shot.absoluteString, "v1": frame.absoluteString, "v2": frame.absoluteString,
        ]))
        try #require(media.count == 3)
        let widths = media.map { $0.row.size.width }
        let shownWidths = widths.map { String(describing: $0) }.joined(separator: ", ")
        #expect(Set(widths).count == 1, "pictures and videos of one message at widths \(shownWidths)")
        let lefts = media.map { RowDraw.bodyRect($0.spec).minX }
        let shownLefts = lefts.map { String(describing: $0) }.joined(separator: ", ")
        #expect(Set(lefts).count == 1, "and one edge: \(shownLefts)")
        for video in media where video.a.kind == "video" {
            let aspect = video.row.size.width / video.row.size.height
            let drawn = String(describing: video.row.size)
            #expect(abs(aspect - 16.0 / 9.0) < 0.03, "a 16:9 video drawn at \(drawn)")
        }
    }

    /// One picture alone keeps its own size (the rule for a single photo is unchanged).
    @Test func aSinglePictureKeepsItsNaturalWidth() throws {
        let dir = try Self.folder()
        let small = try Self.png(200, 100, in: dir)
        let media = Self.mediaRows(Self.rows([
            .attachment(AttachmentRef(hash: "s", name: "s.png", mimeType: "image/png", byteCount: 900, width: 200, height: 100)),
        ], pictures: ["s": small.absoluteString]))
        try #require(media.count == 1)
        let drawn = String(describing: media[0].row.size)
        #expect(media[0].row.size.width == 100, "a 200 px picture at 2x is 100 pt: \(drawn)")
    }

    // MARK: Nothing drawn beside a picture

    /// Columns of the row's bitmap with any pixel, outside the picture's frame (and the tail's 8 pt), at its height.
    static func drawsBeside(_ spec: RowSpec) throws -> Bool {
        let body = RowDraw.bodyRect(spec)
        let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
        let image = try #require(WideBitmap.make(size: size, scale: 1, opaque: false) { ctx in RowDraw.drawStatic(spec, ctx, windowY: .nan) })
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let rows = max(0, Int(body.minY))..<min(h, Int(body.maxY.rounded(.up)))
        let outside = (0..<w).filter { x in CGFloat(x) < body.minX - 8 || CGFloat(x) > body.maxX + 8 }
        for y in rows { for x in outside where pixels[(y * w + x) * 4 + 3] > 8 { return true } }
        return false
    }

    /// The save glyph that sat 14 pt beside every picture and video (and took no click) is gone, on both sides.
    @Test(arguments: [Self.chief, Self.me])
    func nothingIsDrawnBesideAPictureOrVideo(author: ParticipantID) throws {
        let dir = try Self.folder()
        let shot = try Self.png(1200, 800, in: dir)
        let media = Self.mediaRows(Self.rows([
            .attachment(AttachmentRef(hash: "p", name: "p.png", mimeType: "image/png", byteCount: 9000, width: 1200, height: 800)),
            .attachment(AttachmentRef(hash: "v", name: "v.mp4", mimeType: "video/mp4", byteCount: 9000, width: 1280, height: 720)),
        ], author: author, pictures: ["p": shot.absoluteString]))
        try #require(media.count == 2)
        for m in media {
            let beside = try Self.drawsBeside(m.spec)
            let what = "\(m.a.kind) row of \(author.rawValue)"
            #expect(!beside, "\(what) draws beside its frame")
        }
    }
}
