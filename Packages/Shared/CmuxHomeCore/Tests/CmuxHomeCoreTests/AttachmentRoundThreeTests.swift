import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxHomeCore

// Regression tests for the third attachment review (minor findings 1-6).

/// A `width` x `height` PNG with an alpha channel and every pixel opaque.
func makeOpaquePNGWithAlpha(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.1, green: 0.5, blue: 0.3, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite(.timeLimit(.minutes(3))) struct AttachmentRoundThreePreparationTests {
    /// Minor 1: a timed metadata track whose format names no location (an
    /// iPhone's orientation or still-image-time track) is not location, so
    /// the file is sent as it is, with no export.
    @MainActor @Test func aVideoWithoutLocationSendsWithoutAnExport() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
        let movie = root.appendingPathComponent("plain.mov")
        try await makeMovie(at: movie, width: 64, height: 32, timedLocation: "portrait",
                            timedIdentifier: AVMetadataIdentifier("mdta/com.apple.quicktime.video-orientation"))
        try #require(try await movieLocation(movie).timedTracks == 1, "fixture must carry a timed metadata track")
        let prepared = try await store.prepareAttachment(fileURL: movie)
        #expect(prepared.ref.hash == sha256Hex(try Data(contentsOf: movie)))
    }

    /// Minor 1: a text track can hold positions (a drone writes GPS as
    /// subtitles): it is dropped unless the user keeps location.
    @MainActor @Test func aTextTrackIsDroppedUnlessLocationIsKept() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
        let movie = root.appendingPathComponent("drone.mov")
        try await makeMovie(at: movie, width: 64, height: 32, subtitle: "GPS(37.3349,-122.0090) BAROMETER:42.1M")
        try #require(try await AVURLAsset(url: movie).loadTracks(withMediaType: .text).count == 1,
                     "fixture must carry a text track")

        let stripped = try await store.prepareAttachment(fileURL: movie)
        let asset = AVURLAsset(url: stripped.fileURL)
        #expect(try await asset.loadTracks(withMediaType: .text).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(stripped.ref.hash == sha256Hex(try Data(contentsOf: stripped.fileURL)))

        let kept = try await store.prepareAttachment(fileURL: movie, keepLocation: true)
        #expect(kept.ref.hash == sha256Hex(try Data(contentsOf: movie)))
    }

    /// Minor 2 (Lawrence's rule: transparent images get no preview): an
    /// opaque PNG that only has an alpha channel gets its JPEG preview, so
    /// readers do not download the original.
    @MainActor @Test func anOpaquePNGWithAnAlphaChannelGetsAPreview() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let png = try makeOpaquePNGWithAlpha(width: 2400, height: 1200)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        try #require(properties?[kCGImagePropertyHasAlpha] as? Bool == true, "fixture must have an alpha channel")

        let prepared = try await store.prepareAttachment(data: png, typeIdentifier: UTType.png.identifier)
        let preview = try #require(prepared.ref.preview)
        #expect(preview.mimeType == "image/jpeg")
        #expect(prepared.previewURL != nil)
    }

    /// Minor 6: a WebP whose location is in its EXIF chunk (orientation 1)
    /// keeps its own bytes minus that chunk: still a WebP, every frame and
    /// the animation kept, no larger than before.
    @MainActor @Test func aWebPWithLocationDropsItsEXIFChunkAndStaysAWebP() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
        let webp = try makeWebPWithLocation(orientation: 1)
        try #require(try imageHasLocation(webp), "fixture must carry GPS")
        let file = root.appendingPathComponent("sticker.webp")
        try webp.write(to: file)

        let stripped = try await store.prepareAttachment(fileURL: file)
        let bytes = try Data(contentsOf: stripped.fileURL)
        #expect(try !imageHasLocation(bytes))
        #expect(stripped.ref.mimeType == "image/webp")
        #expect(stripped.ref.name == "sticker.webp")
        #expect(stripped.ref.hash == sha256Hex(bytes))
        #expect(bytes.count < webp.count)
    }

    /// Minor 6: a thumbnail an earlier build cached as `thumb-N.jpg` (a
    /// transparent image drawn on black) is not reused.
    @MainActor @Test func aThumbnailFromAnEarlierBuildIsReplaced() async throws {
        let root = try temporaryDirectory()
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        let prepared = try await store.prepareAttachment(data: try makeTransparentPNG(width: 400, height: 200),
                                                         typeIdentifier: UTType.png.identifier)
        let directory = prepared.fileURL.deletingLastPathComponent()
        let legacy = directory.appendingPathComponent("thumb-200.jpg")
        try makeJPEG(width: 200, height: 100, orientation: 1).write(to: legacy)

        let thumb = try await store.fetchAttachment(prepared.ref, variant: .thumbnail(maxPixel: 200),
                                                    in: ConversationID("conv_austin"))
        #expect(thumb.pathExtension == "png")
        #expect(try minimumAlpha(thumb) == 0)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(3))) struct AttachmentRoundThreeSendTests {
    let conversation = ConversationID("conv_austin")

    func started(clock: ManualClock = ManualClock()) async throws -> (HomeStore, MockHomeSource) {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory(), clock: clock)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        await waitUntil { !store.transcript(for: self.conversation).isEmpty }
        return (store, source)
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<5_000 where !condition() { await Task.yield() }
    }

    func drainTasks() async {
        for _ in 0..<500 { await Task.yield() }
    }

    func text(_ value: String) -> HomeOp { .sendMessage(conversation: conversation, parts: [.text(value)]) }

    func row(_ key: IdempotencyKey, in store: HomeStore) -> TranscriptItem? {
        store.transcript(for: conversation).first { $0.key == key }
    }

    /// Advances the clock through every resend backoff until the row stops sending.
    func runOutResends(_ key: IdempotencyKey, store: HomeStore, clock: ManualClock) async {
        var steps = 0
        while row(key, in: store)?.delivery == .sending, steps < 20 {
            clock.advance(by: .seconds(600))
            await drainTasks()
            steps += 1
        }
    }

    func attachmentMessages(_ hash: String, in source: MockHomeSource) async throws -> Int {
        try await source.snapshot(of: conversation, tail: 20).messages.filter { message in
            message.parts.contains { if case .attachment(let ref) = $0 { ref.hash == hash } else { false } }
        }.count
    }

    /// Minors 3 and 4: the owner commits the send but the answer and the
    /// echo are lost, and every resend goes unanswered. The row fails as a
    /// send that may have been delivered (not a refusal: `onRefusal` stays
    /// quiet); retry replays the owner's first commit under the same key,
    /// and the echo leaves one committed row.
    @Test func aCommitWhoseAnswerIsLostReplaysAfterNotDelivered() async throws {
        let clock = ManualClock()
        let (store, source) = try await started(clock: clock)
        var refused: [HomeIntent] = []
        store.onRefusal = { intent, _ in refused.append(intent) }
        let key = IdempotencyKey("lost-answer")
        await source.commitThenLoseAnswer(of: key, failingAfter: 1_000)
        await #expect(throws: HomeSendState.pendingResend) { try await store.perform(text("lost"), key: key) }
        try #require(try await source.snapshot(of: conversation, tail: 5).messages.contains { $0.clientMessageID == key },
                     "the owner committed it")

        await runOutResends(key, store: store, clock: clock)
        let failed = try #require(row(key, in: store))
        #expect(failed.delivery == .notDelivered(.indeterminate))
        #expect(failed.mayHaveBeenDelivered)
        #expect(refused.isEmpty, "running out of resends is not a refusal")

        await source.failNextSubmits(of: key, times: 0)
        try await store.retry(key)
        let page = try await source.snapshot(of: conversation, tail: 10)
        #expect(page.messages.filter { $0.clientMessageID == key }.count == 1)
        await source.releaseWithheldEvents()
        await waitUntil { store.log.isEmpty }
        let rows = store.transcript(for: conversation).filter { $0.key == key }
        #expect(rows.map(\.delivery) == [.committed])
        #expect(refused.isEmpty)
    }

    /// Minor 4: an upload that runs out of resends never reached the owner:
    /// "Not Delivered" without "may have been delivered", and no refusal.
    @Test func anUnansweredUploadIsNotDeliveredAndNotARefusal() async throws {
        let clock = ManualClock()
        let (store, source) = try await started(clock: clock)
        var refused: [HomeIntent] = []
        store.onRefusal = { intent, _ in refused.append(intent) }
        let a = try await store.prepareAttachment(data: Data("never uploads".utf8), typeIdentifier: UTType.plainText.identifier)
        let key = IdempotencyKey("upload-unanswered")
        await source.failNextUpload(hash: a.ref.hash, with: .indeterminate, times: 1_000)
        let send = Task { try await store.send(conversation: conversation, text: "", attachments: [a], key: key) }
        var steps = 0
        while row(key, in: store)?.delivery != .notDelivered(.indeterminate), steps < 20 {
            clock.advance(by: .seconds(600))
            await drainTasks()
            steps += 1
        }
        _ = try? await send.value
        let failed = try #require(row(key, in: store))
        #expect(failed.delivery == .notDelivered(.indeterminate))
        #expect(!failed.mayHaveBeenDelivered)
        #expect(refused.isEmpty)
    }

    /// Minor 5: a resend that gets `unknown_attachment` (the owner swept the
    /// upload while the first answer was lost) uploads again and sends once
    /// more by itself; nothing is refused.
    @Test func aResendThatGetsUnknownAttachmentUploadsAgain() async throws {
        let (store, source) = try await started()
        var refused: [HomeRejection] = []
        store.onRefusal = { refused.append($1) }
        let a = try await store.prepareAttachment(data: Data("resent".utf8), typeIdentifier: UTType.plainText.identifier)
        let key = IdempotencyKey("resend-swept")
        await source.failNextSubmits(of: key, times: 1)
        await source.forgetBlobBeforeNextSubmits(a.ref.hash)
        _ = try? await store.send(conversation: conversation, text: "", attachments: [a], key: key)
        await waitUntil { store.log.isEmpty }
        #expect(refused.isEmpty)
        #expect(store.log.isEmpty)
        #expect(try await attachmentMessages(a.ref.hash, in: source) == 1)
    }

    /// Minor 5: a retry under the same key that gets `unknown_attachment`
    /// uploads again and sends once more without a second tap.
    @Test func aRetryThatGetsUnknownAttachmentUploadsAgain() async throws {
        let clock = ManualClock()
        let (store, source) = try await started(clock: clock)
        let a = try await store.prepareAttachment(data: Data("retried".utf8), typeIdentifier: UTType.plainText.identifier)
        let key = IdempotencyKey("retry-swept")
        await source.failNextSubmits(of: key, times: 1_000)
        _ = try? await store.send(conversation: conversation, text: "", attachments: [a], key: key)
        await runOutResends(key, store: store, clock: clock)
        try #require(row(key, in: store)?.delivery == .notDelivered(.indeterminate))

        await source.failNextSubmits(of: key, times: 0)
        await source.forgetBlobBeforeNextSubmits(a.ref.hash)
        _ = try? await store.retry(key)
        await waitUntil { store.log.isEmpty }
        #expect(store.log.isEmpty)
        #expect(try await attachmentMessages(a.ref.hash, in: source) == 1)
        let rows = store.transcript(for: conversation).filter { $0.attachmentHashes == [a.ref.hash] }
        #expect(rows.map(\.delivery) == [.committed])
    }
}
