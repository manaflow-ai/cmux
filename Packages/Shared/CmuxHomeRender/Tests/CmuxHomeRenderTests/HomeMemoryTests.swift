import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// The render caches under the host's memory policy: the host sizes them and takes
/// bytes back, the rows on screen always keep what they show, nothing drawn or loaded is thrown away
/// only to be drawn or loaded again, measurements stay, and a hidden transcript holds no image.
@MainActor
@Suite struct HomeMemoryTests {
    /// A receipt row whose text makes it its own content key.
    private static func receipt(_ i: Int) -> RowSpec {
        RowSpec(key: "r\(i)", kind: .receipt("Read \(i)"), gap: 0, height: 14)
    }

    private static let receiptSize = CGSize(width: 40, height: 62)

    private static func receipts(_ range: Range<Int>) -> [(spec: RowSpec, size: CGSize)] {
        range.map { (spec: receipt($0), size: receiptSize) }
    }

    /// Draws `range` through misses that no row on screen asked for, and waits for them.
    private static func draw(_ bitmaps: RowBitmaps, _ range: Range<Int>) async {
        for i in range { _ = bitmaps.image(for: receipt(i), size: receiptSize) { _ in } }
        await bitmaps.settled()
    }

    /// The bytes of one receipt bitmap.
    private static func oneReceiptBytes() async -> Int {
        let probe = RowBitmaps(palette: Fixtures.palette, maxBytes: 64 << 20)
        await draw(probe, 0..<1)
        return probe.bytes
    }

    /// A controller showing 12 messages, with `count` more distinct row bitmaps drawn and kept.
    private static func controllerWithBitmaps(_ count: Int) async -> HomeController {
        let c = Fixtures.controller(width: 628, height: 900)
        c.memoryBudget = HomeMemoryBudget(bytes: 512 << 20)
        c.update(items: Fixtures.items(Fixtures.conversation(12)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        await draw(c.scene.bitmaps, 0..<count)
        return c
    }

    private static func photo(_ hash: String) -> MediaPart {
        MediaPart(ref: AttachmentRef(hash: hash, name: "\(hash).png", mimeType: "image/png", byteCount: 900, width: 64, height: 48),
                  isVideo: false)
    }

    // MARK: Row bitmaps

    @Test func theCallerSizesTheCacheAndAStorePastItDropsTheOldest() async throws {
        let one = await Self.oneReceiptBytes()
        #expect(one > 0)

        let bitmaps = RowBitmaps(palette: Fixtures.palette, maxBytes: one * 10)
        await Self.draw(bitmaps, 0..<30)
        #expect(bitmaps.bytes <= one * 10, "the caller's cap holds, not a fixed one")
        #expect(bitmaps.count <= 10)
        #expect(bitmaps.count > 0, "a store keeps three quarters of the cap, not nothing")
    }

    @Test func prefetchDrawsAheadOnlyWhatTheBudgetKeeps() async throws {
        let one = await Self.oneReceiptBytes()
        let bitmaps = RowBitmaps(palette: Fixtures.palette, maxBytes: one * 10)

        bitmaps.prefetch(Self.receipts(0..<30))
        await bitmaps.settled()
        let drawn = bitmaps.renderCount
        #expect(drawn > 0)
        #expect(drawn <= 10, "rows past the budget wait until they scroll in")

        bitmaps.prefetch(Self.receipts(0..<30))
        await bitmaps.settled()
        #expect(bitmaps.renderCount == drawn, "what was drawn ahead is kept, and nothing is drawn again")

        let empty = RowBitmaps(palette: Fixtures.palette, maxBytes: 0)
        empty.prefetch(Self.receipts(0..<30))
        #expect(empty.renderCount == 0, "a zero budget draws nothing ahead")
    }

    @Test func aZeroBudgetKeepsTheRowsOnScreenAndLayoutDrawsNothingAgain() async throws {
        let c = Fixtures.controller(width: 628, height: 900)
        c.memoryBudget = .zero
        c.update(items: Fixtures.items(Fixtures.conversation(60)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        await c.bitmapsSettled()
        #expect(c.scene.visible.values.allSatisfy { $0.bitmap.contents != nil })
        #expect(c.scene.bitmaps.bytes > 0, "the rows on screen keep their bitmaps at any budget")
        #expect(c.scene.bitmaps.bytes == c.scene.bitmaps.shownCachedBytes, "and nothing else is kept")

        let drawn = c.scene.bitmaps.renderCount
        for _ in 0..<2 {
            c.scene.layoutRows()  // every scroll and commit ends here
            await c.bitmapsSettled()
        }
        #expect(c.scene.bitmaps.renderCount == drawn, "no layout draws rows ahead only to throw them away")
    }

    @Test func sixHundredRowsTrimToHalfThenToTheRowsOnScreenAndDrawAgainOnRequest() async throws {
        let c = await Self.controllerWithBitmaps(600)
        let full = c.memoryBytes
        #expect(c.scene.bitmaps.count >= 600, "600 distinct rows are kept under a 512 MiB budget")

        c.trim(toFraction: 0.5)
        #expect(c.memoryBytes <= full / 2)
        #expect(c.memoryBytes > 0)

        c.trim(toFraction: 0)
        #expect(c.memoryBytes == c.scene.bitmaps.shownCachedBytes, "only what the rows on screen show is left")
        #expect(c.scene.visible.values.allSatisfy { $0.bitmap.contents != nil })

        let rendered = c.scene.bitmaps.renderCount
        var installed: CGImage?
        #expect(c.scene.bitmaps.image(for: Self.receipt(0), size: Self.receiptSize) { installed = $0 } == nil, "a trimmed row is a miss")
        await c.scene.bitmaps.settled()
        #expect(c.scene.bitmaps.renderCount == rendered + 1, "the miss drew it again")
        #expect(installed != nil)
        #expect(c.scene.bitmaps.image(for: Self.receipt(0), size: Self.receiptSize) { _ in } != nil, "and keeps it")
    }

    @Test func aLowerBudgetFreesNothingUntilTheNextStore() async throws {
        let c = await Self.controllerWithBitmaps(40)
        let held = c.scene.bitmaps.bytes

        c.memoryBudget = .zero
        #expect(c.scene.bitmaps.bytes == held, "lowering the cap only stops growth")

        c.scene.layoutRows()  // the next layout offers no row ahead at budget 0
        await Self.draw(c.scene.bitmaps, 1_000..<1_001)
        #expect(c.scene.bitmaps.bytes == c.scene.bitmaps.shownCachedBytes, "the store dropped all but the rows on screen")
    }

    // MARK: Measurements

    @Test func aTrimKeepsTheMeasurementsSoTheNextCommitMeasuresOnlyWhatChanged() async throws {
        let c = Fixtures.controller(width: 628, height: 900)
        var messages = Fixtures.conversation(40)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        await c.bitmapsSettled()
        let measurements = c.measurementBytes
        #expect(measurements > 0)

        c.trim(toFraction: 0)
        #expect(c.measurementBytes == measurements, "every commit reads them: no trim drops them")

        let measured = c.builder.measure.measureCount
        messages.append(Fixtures.message(41, Fixtures.chief, "One more."))
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(c.builder.measure.measureCount - measured == 1, "only the new part is measured")
    }

    // MARK: Hidden

    @Test func aHiddenTranscriptHoldsNoImageAndDrawsNothingUntilItShows() async throws {
        let c = Fixtures.controller(width: 628, height: 900)
        c.attachmentLoader = FakeAttachmentLoader()
        var messages = Fixtures.conversation(30)
        messages.append(AttachmentFixtures.message(31, Fixtures.chief, [.attachment(AttachmentFixtures.photo)]))
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        await c.bitmapsSettled()
        await c.attachmentsSettled()
        #expect(c.scene.media.bytes > 0)
        c.scene.hostScroll(to: c.scene.offset - 600)
        await c.bitmapsSettled()
        #expect(!c.scene.pool.isEmpty, "rows that scrolled away are pooled")

        c.setHidden(true)
        #expect(c.isHidden)
        #expect(c.memoryBytes == 0)
        #expect(c.scene.visible.isEmpty)
        #expect(!c.scene.bitmaps.isRendering)
        #expect(c.scene.pool.allSatisfy { $0.bitmap.contents == nil && $0.receiptOld.contents == nil && $0.mediaImage.contents == nil },
                "no row layer keeps an image the caches let go")
        #expect(c.measurementBytes > 0, "measurements stay")

        let drawn = c.scene.bitmaps.renderCount
        let measured = c.builder.measure.measureCount
        messages.append(Fixtures.message(32, Fixtures.me, "Ship it."))
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        await c.bitmapsSettled()
        #expect(c.scene.bitmaps.renderCount == drawn, "a hidden transcript updates its model only")
        #expect(c.builder.measure.measureCount - measured == 1)
        #expect(c.memoryBytes == 0)

        c.setHidden(false)
        #expect(!c.scene.visible.isEmpty, "showing lays out once")
        await c.bitmapsSettled()
        #expect(c.scene.visible.values.allSatisfy { $0.bitmap.contents != nil }, "the rows on screen draw again")
        #expect(c.memoryBytes > 0)
    }

    // MARK: Pictures

    @Test func aPictureOverTheBudgetStillReachesItsRowOnceAndIsNotKept() async throws {
        let media = MediaStore(maxBytes: 0)
        let loader = FakeAttachmentLoader()
        media.loader = loader
        var arrived: [String] = []
        let part = MediaPart(ref: AttachmentFixtures.photo, isVideo: false)
        var shown: CGImage?
        media.onImage = { [weak media] hash in
            arrived.append(hash)
            shown = media?.image(for: part, maxPixel: 64)
        }

        #expect(media.image(for: part, maxPixel: 64) == nil)
        await media.settled()

        #expect(arrived == [AttachmentFixtures.photo.hash])
        #expect(shown != nil, "the row read the picture before the cache let it go")
        #expect(media.bytes == 0, "no row on screen shows it")
        let requests = await loader.thumbnailRequests.count
        #expect(requests == 1, "showing it did not start a second load")
    }

    @Test func aPictureOnScreenIsKeptAtAZeroBudgetAndNotLoadedAgainOnTheNextCommits() async throws {
        let loader = FakeAttachmentLoader()
        let c = Fixtures.controller(height: 900)
        c.memoryBudget = .zero
        c.attachmentLoader = loader
        var messages = Fixtures.conversation(6)
        messages.append(AttachmentFixtures.message(7, Fixtures.chief, [.attachment(AttachmentFixtures.photo)]))
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        await c.attachmentsSettled()
        #expect(c.scene.visible["part:key_7:0"]?.mediaImage.contents != nil)
        #expect(c.scene.media.bytes > 0, "the picture on screen stays although the budget is 0")

        for seq in [Seq(8), Seq(9)] {
            messages.append(Fixtures.message(seq, Fixtures.me, "Nice"))
            c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
            await c.attachmentsSettled()
        }
        #expect(c.scene.visible["part:key_7:0"]?.mediaImage.contents != nil)
        let requests = await loader.thumbnailRequests.count
        #expect(requests == 1, "a commit never loads a picture on screen again")
    }

    @Test func aHitMakesAPictureTheMostRecentlyUsed() async throws {
        let media = MediaStore(maxBytes: 64 << 20)
        media.loader = FakeAttachmentLoader()
        let parts = ["a", "b", "c"].map(Self.photo)
        for part in parts.prefix(2) {
            _ = media.image(for: part, maxPixel: 64)
            await media.settled()
        }
        #expect(media.count == 2)
        media.maxBytes = media.bytes

        #expect(media.image(for: parts[0], maxPixel: 64) != nil, "a hit")
        _ = media.image(for: parts[2], maxPixel: 64)
        await media.settled()

        #expect(media.count == 2, "one picture went")
        #expect(media.image(for: parts[0], maxPixel: 64) != nil, "not the one just used")
    }
}
