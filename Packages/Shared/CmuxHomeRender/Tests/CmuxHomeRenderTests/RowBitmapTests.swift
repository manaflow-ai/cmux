import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// Row bitmaps are drawn off the main actor: a miss never draws in the
/// caller, and the main actor only installs the finished image.
@MainActor
@Suite struct RowBitmapTests {
    @Test func aMissDrawsOffTheMainActorAndInstallsLater() async throws {
        let c = Fixtures.controller(width: 628, height: 900)
        c.update(items: Fixtures.items(Fixtures.conversation(12)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(c.scene.bitmaps.isRendering, "visible rows started render jobs")
        #expect(c.scene.visible.values.allSatisfy { $0.bitmap.contents == nil }, "nothing was drawn synchronously")
        await c.scene.bitmaps.settled()
        #expect(!c.scene.bitmaps.isRendering)
        #expect(c.scene.visible.values.allSatisfy { $0.bitmap.contents != nil }, "every visible row got its bitmap")
    }

    @Test func equalContentSharesOneJobAndHitsTheCacheAfterwards() async throws {
        let bitmaps = RowBitmaps(palette: Fixtures.palette, maxBytes: 64 << 20)
        let spec = RowSpec(key: "a", kind: .receipt("Read"), gap: 0, height: 14)
        var installed = 0
        let size = CGSize(width: 40, height: 62)
        #expect(bitmaps.image(for: spec, size: size) { _ in installed += 1 } == nil)
        var other = spec
        other.key = "b"
        #expect(bitmaps.image(for: other, size: size) { _ in installed += 1 } == nil)
        #expect(bitmaps.renderCount == 1, "one job per content key")
        await bitmaps.settled()
        #expect(installed == 2)
        #expect(bitmaps.image(for: spec, size: size) { _ in installed += 1 } != nil, "a hit returns at once")
        #expect(bitmaps.renderCount == 1)
    }

    @Test func aPaletteChangeDropsJobsInFlight() async throws {
        let bitmaps = RowBitmaps(palette: Fixtures.palette, maxBytes: 64 << 20)
        let spec = RowSpec(key: "a", kind: .receipt("Read"), gap: 0, height: 14)
        var installed = 0
        _ = bitmaps.image(for: spec, size: CGSize(width: 40, height: 62)) { _ in installed += 1 }
        bitmaps.setPalette(HomePalette.themed(Fixtures.theme, active: false))
        #expect(!bitmaps.isRendering)
        await bitmaps.settled()
        // Let the cancelled job reach the main actor and be ignored.
        for _ in 0..<1000 { await Task.yield() }
        #expect(installed == 0, "an old palette's image is never installed")
    }

    // MARK: Memory (p07-memory-080): the host sizes the caches and takes bytes back

    /// A receipt row whose text makes it its own content key.
    private static func receipt(_ i: Int) -> RowSpec {
        RowSpec(key: "r\(i)", kind: .receipt("Read \(i)"), gap: 0, height: 14)
    }

    private static let receiptSize = CGSize(width: 40, height: 62)

    /// A controller with `count` distinct row bitmaps drawn and kept.
    private static func controllerWithBitmaps(_ count: Int) async -> HomeController {
        let c = Fixtures.controller(width: 628, height: 900)
        c.memoryBudget = HomeMemoryBudget(bytes: 512 << 20)
        c.update(items: Fixtures.items(Fixtures.conversation(12)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        for i in 0..<count { c.scene.bitmaps.prefetch(receipt(i), size: receiptSize) }
        await c.scene.bitmaps.settled()
        return c
    }

    @Test func theCallerSizesTheCacheAndAStorePastItDropsTheOldest() async throws {
        let probe = RowBitmaps(palette: Fixtures.palette, maxBytes: 64 << 20)
        probe.prefetch(Self.receipt(0), size: Self.receiptSize)
        await probe.settled()
        let one = probe.bytes
        #expect(one > 0)

        let bitmaps = RowBitmaps(palette: Fixtures.palette, maxBytes: one * 10)
        for i in 0..<30 { bitmaps.prefetch(Self.receipt(i), size: Self.receiptSize) }
        await bitmaps.settled()
        #expect(bitmaps.bytes <= one * 10, "the caller's cap holds, not a fixed one")
        #expect(bitmaps.count <= 10)
        #expect(bitmaps.count > 0, "a trim keeps three quarters of the cap, not nothing")
    }

    @Test func sixHundredRowsTrimToHalfThenToNothingAndDrawAgainOnRequest() async throws {
        let c = await Self.controllerWithBitmaps(600)
        let full = c.memoryBytes
        #expect(c.scene.bitmaps.count >= 600, "600 distinct rows are kept under a 512 MiB budget")

        c.trim(toFraction: 0.5)
        #expect(c.memoryBytes <= full / 2)
        #expect(c.memoryBytes > 0)

        c.trim(toFraction: 0)
        #expect(c.memoryBytes == 0)
        #expect(c.memoryEntryCount == 0)

        let rendered = c.scene.bitmaps.renderCount
        var installed: CGImage?
        #expect(c.scene.bitmaps.image(for: Self.receipt(0), size: Self.receiptSize) { installed = $0 } == nil, "a trimmed row is a miss")
        await c.scene.bitmaps.settled()
        #expect(c.scene.bitmaps.renderCount == rendered + 1, "the miss drew it again")
        #expect(installed != nil)
        #expect(c.scene.bitmaps.image(for: Self.receipt(0), size: Self.receiptSize) { _ in } != nil, "and keeps it")
    }

    @Test func aHiddenControllerReportsZeroBytesAndRowsInFlightStillGetTheirBitmap() async throws {
        let c = Fixtures.controller(width: 628, height: 900)
        c.update(items: Fixtures.items(Fixtures.conversation(12)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(c.scene.bitmaps.isRendering)

        c.releaseHidden()
        await c.scene.bitmaps.settled()

        #expect(c.memoryBytes == 0, "nothing drawn for a hidden transcript is kept")
        #expect(c.scene.visible.values.allSatisfy { $0.bitmap.contents != nil }, "rows that asked still got their bitmap")
    }

    @Test func aLowerBudgetFreesNothingUntilTheNextStore() async throws {
        let c = await Self.controllerWithBitmaps(40)
        let held = c.scene.bitmaps.bytes

        c.memoryBudget = .zero
        #expect(c.scene.bitmaps.bytes == held, "lowering the cap only stops growth")

        c.scene.bitmaps.prefetch(Self.receipt(1_000), size: Self.receiptSize)
        await c.scene.bitmaps.settled()
        #expect(c.scene.bitmaps.bytes == 0)
    }

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
        #expect(media.bytes == 0)
        let requests = await loader.thumbnailRequests.count
        #expect(requests == 1, "showing it did not start a second load")
    }
}
