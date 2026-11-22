import CoreGraphics
import Foundation
import ImageIO
import Testing
import CmuxHomeCoreTestSupport
import UniformTypeIdentifiers
@testable import CmuxHomeCore

// Regression tests for the fourth attachment review (minor findings 1, 2, 3 and 6).

private func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xff) } }

private func webPChunk(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
    Array(tag.utf8) + le32(payload.count) + payload + (payload.count % 2 == 1 ? [0] : [])
}

private func riff(_ chunks: [UInt8]) -> Data {
    let body = Array("WEBP".utf8) + chunks
    return Data(Array("RIFF".utf8) + le32(body.count) + body)
}

/// The payload of the first `tag` chunk of a WebP.
private func webPChunkPayload(_ tag: String, in data: Data) -> [UInt8]? {
    let bytes = [UInt8](data)
    var index = 12
    while index + 8 <= bytes.count {
        let size = (0..<4).reduce(0) { $0 | Int(bytes[index + 4 + $1]) << (8 * $1) }
        guard index + 8 + size <= bytes.count else { return nil }
        if bytes[index..<(index + 4)].elementsEqual(tag.utf8) { return Array(bytes[(index + 8)..<(index + 8 + size)]) }
        index += 8 + size + (size & 1)
    }
    return nil
}

/// A 1x1 VP8L frame (the same bitstream `makeWebPWithLocation` uses).
private let vp8lPixel: [UInt8] = [0x2f, 0x00, 0x00, 0x00, 0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xfe, 0x07]

/// A two-frame animated 1x1 WebP whose EXIF chunk holds GPS (orientation 1).
private func makeAnimatedWebPWithLocation() throws -> Data {
    let exif = try #require(webPChunkPayload("EXIF", in: try makeWebPWithLocation(orientation: 1)))
    let vp8x: [UInt8] = [0x1A, 0, 0, 0, 0, 0, 0, 0, 0, 0] // alpha + EXIF + animation, 1x1 canvas
    let anim: [UInt8] = [0, 0, 0, 0, 0, 0] // background color, loop forever
    // x/2, y/2, width-1, height-1 (24 bits each), duration 100 ms, no blend.
    let frameHeader: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0, 0x02]
    let frame = webPChunk("ANMF", frameHeader + webPChunk("VP8L", vp8lPixel))
    return riff(webPChunk("VP8X", vp8x) + webPChunk("ANIM", anim) + frame + frame + webPChunk("EXIF", exif))
}

private func frameCount(_ data: Data) -> Int {
    CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
}

@Suite(.timeLimit(.minutes(3))) struct WebPStripTests {
    /// Minor 2: 1 to 7 bytes after the RIFF data are dropped, not refused,
    /// so the WebP is not converted to its first frame.
    @Test func oneToSevenTrailingBytesAreDropped() throws {
        let webp = try makeWebPWithLocation(orientation: 1)
        let clean = try #require(AttachmentMedia.webPWithoutMetadataChunks(webp))
        for count in 1...7 {
            let padded = webp + Data(repeating: 0xAB, count: count)
            #expect(AttachmentMedia.webPWithoutMetadataChunks(padded) == clean, "\(count) trailing bytes")
        }
    }

    /// Minor 2: 8 or more bytes after the RIFF data are not read as chunks,
    /// so whatever they hold is not sent.
    @Test func eightOrMoreTrailingBytesAreNotSent() throws {
        let webp = try makeWebPWithLocation(orientation: 1)
        let clean = try #require(AttachmentMedia.webPWithoutMetadataChunks(webp))
        let secret = Array("SECRETSECRET".utf8)
        let padded = webp + Data(webPChunk("JUNK", secret))
        let stripped = try #require(AttachmentMedia.webPWithoutMetadataChunks(padded))
        #expect(stripped == clean)
        #expect(stripped.range(of: Data(secret)) == nil)
        let eight = webp + Data(repeating: 0, count: 8)
        #expect(AttachmentMedia.webPWithoutMetadataChunks(eight) == clean)
    }

    /// Minor 3: the VP8X flags lose EXIF (0x08) and keep alpha (0x10).
    @Test func theVP8XFlagsLoseOnlyEXIFAndXMP() throws {
        let webp = try makeWebPWithLocation(orientation: 1)
        #expect(webPChunkPayload("VP8X", in: webp)?.first == 0x18)
        let stripped = try #require(AttachmentMedia.webPWithoutMetadataChunks(webp))
        #expect(webPChunkPayload("VP8X", in: stripped)?.first == 0x10)
        #expect(webPChunkPayload("EXIF", in: stripped) == nil)
    }

    /// Minor 3: an animated WebP keeps its ANIM and ANMF chunks byte for
    /// byte, and ImageIO still reads both frames.
    @Test func anAnimatedWebPKeepsItsFrames() throws {
        let webp = try makeAnimatedWebPWithLocation()
        let stripped = try #require(AttachmentMedia.webPWithoutMetadataChunks(webp))
        #expect(webPChunkPayload("VP8X", in: stripped)?.first == 0x12)
        #expect(webPChunkPayload("ANIM", in: stripped) == webPChunkPayload("ANIM", in: webp))
        #expect(webPChunkPayload("ANMF", in: stripped) == webPChunkPayload("ANMF", in: webp))
        #expect(webPChunkPayload("EXIF", in: stripped) == nil)
        try #require(frameCount(webp) == 2, "ImageIO must read the fixture's two frames")
        #expect(frameCount(stripped) == 2)
    }

    /// Minor 3: truncated or malformed input gives nil, never a crash.
    @Test func truncatedOrMalformedInputGivesNil() throws {
        let webp = try makeWebPWithLocation(orientation: 1)
        #expect(AttachmentMedia.webPWithoutMetadataChunks(webp.prefix(webp.count - 5)) == nil, "last chunk cut short")
        #expect(AttachmentMedia.webPWithoutMetadataChunks(webp.prefix(11)) == nil, "no header")
        var small = [UInt8](webp)
        small.replaceSubrange(4..<8, with: le32(2))
        #expect(AttachmentMedia.webPWithoutMetadataChunks(Data(small)) == nil, "RIFF size below 4")
        var cut = [UInt8](webp)
        cut.replaceSubrange(4..<8, with: le32(4 + 12)) // ends inside the VP8X chunk
        #expect(AttachmentMedia.webPWithoutMetadataChunks(Data(cut)) == nil, "RIFF size ends inside a chunk")
        var huge = [UInt8](webp)
        huge.replaceSubrange(16..<20, with: [0xF0, 0xFF, 0xFF, 0xFF])
        #expect(AttachmentMedia.webPWithoutMetadataChunks(Data(huge)) == nil, "chunk size past the end")
        var notWebP = [UInt8](webp)
        notWebP.replaceSubrange(8..<12, with: Array("AVI ".utf8))
        #expect(AttachmentMedia.webPWithoutMetadataChunks(Data(notWebP)) == nil)
    }

    /// Minor 2 end to end: an animated WebP with location and 3 trailing
    /// bytes is still sent as an animated WebP, without its location.
    @MainActor @Test func anAnimatedWebPWithTrailingBytesStaysAnimated() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
        let webp = try makeAnimatedWebPWithLocation() + Data([1, 2, 3])
        try #require(try imageHasLocation(webp), "fixture must carry GPS")
        let file = root.appendingPathComponent("wave.webp")
        try webp.write(to: file)

        let prepared = try await store.prepareAttachment(fileURL: file)
        let bytes = try Data(contentsOf: prepared.fileURL)
        #expect(prepared.ref.mimeType == "image/webp")
        #expect(try !imageHasLocation(bytes))
        #expect(frameCount(bytes) == 2)
    }

    /// Minor 3 end to end: a truncated WebP with location is never sent
    /// with its location (refused, or converted without it).
    @MainActor @Test func aTruncatedWebPNeverSendsItsLocation() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
        var webp = [UInt8](try makeWebPWithLocation(orientation: 1))
        webp.replaceSubrange(4..<8, with: le32(webp.count)) // claims 8 bytes more than it has
        let file = root.appendingPathComponent("cut.webp")
        try Data(webp).write(to: file)
        if let prepared = try? await store.prepareAttachment(fileURL: file) {
            #expect(try !imageHasLocation(try Data(contentsOf: prepared.fileURL)))
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(3))) struct UnansweredOpTests {
    let conversation = ConversationID("conv_austin")

    /// Minor 1: a reaction whose resends all go unanswered leaves the log
    /// and reaches the host through `onUnanswered` (not `onRefusal`: the
    /// owner never said no), instead of vanishing with no message.
    @Test func anUnansweredReactionReachesTheHost() async throws {
        let clock = ManualClock()
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory(), clock: clock)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        await waitUntil { store.transcript(for: self.conversation).contains { $0.seq != nil } }
        let message = try #require(store.transcript(for: conversation).last { $0.seq != nil }?.messageID)
        var unanswered: [HomeIntent] = []
        var refused: [HomeIntent] = []
        store.onUnanswered = { unanswered.append($0) }
        store.onRefusal = { intent, _ in refused.append(intent) }
        let key = IdempotencyKey("tapback-unanswered")
        await source.failNextSubmits(of: key, times: 1_000)
        let op = HomeOp.addReaction(message: message, conversation: conversation, reaction: .tapback(.love), partIndex: 0)
        await #expect(throws: HomeSendState.pendingResend) { try await store.perform(op, key: key) }

        var steps = 0
        while store.log.entries.contains(where: { $0.intent.key == key }), steps < 20 {
            clock.advance(by: .seconds(600))
            for _ in 0..<500 { await Task.yield() }
            steps += 1
        }
        #expect(!store.log.entries.contains { $0.intent.key == key })
        #expect(unanswered.map(\.key) == [key])
        #expect(refused.isEmpty)
        store.stop()
    }

    /// Minor 1: an unanswered send keeps its "Not Delivered" row and does
    /// not call `onUnanswered`.
    @Test func anUnansweredSendKeepsItsRowAndIsNotReported() async throws {
        let clock = ManualClock()
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory(), clock: clock)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        var unanswered: [HomeIntent] = []
        store.onUnanswered = { unanswered.append($0) }
        let key = IdempotencyKey("send-unanswered")
        await source.failNextSubmits(of: key, times: 1_000)
        _ = try? await store.perform(.sendMessage(conversation: conversation, parts: [.text("hi")]), key: key)
        var steps = 0
        while store.transcript(for: conversation).first(where: { $0.key == key })?.delivery == .sending, steps < 20 {
            clock.advance(by: .seconds(600))
            for _ in 0..<500 { await Task.yield() }
            steps += 1
        }
        #expect(store.transcript(for: conversation).first { $0.key == key }?.delivery == .notDelivered(.indeterminate))
        #expect(unanswered.isEmpty)
        store.stop()
    }

}
