import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextMemory
import CmuxNextSettings
import CoreGraphics
import Foundation
import Testing

/// Hibernated pages' pictures are sized from the cache's `ImageCacheShares.hibernationSnapshotBytes` and
/// follow the memory coordinator as a lossy consumer: a limit scales the bytes kept, the
/// pictures of the tabs beside a shown tab stay at any limit, and the critical limit keeps only those,
/// compressed or decoded, and takes no picture it would drop.
@MainActor @Suite(.serialized)
struct HibernationSnapshotsTests {
    /// A 16 x 4 picture's kept pixels: rows of 64 bytes.
    private static let pictureBytes = PurgeableBitmap.byteCount(width: 16, height: 4)

    private static func image(width: Int = 16, height: Int = 4) throws -> CGImage {
        let context = try #require(CGContext.bitmapOwningPixels(width: width, height: height, space: CGColorSpaceCreateDeviceRGB(),
                                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    /// One picture of `pictureBytes` in pages from `allocator`.
    private func picture(allocator: PurgeableAllocator = .resident) throws -> PurgeablePicture {
        try #require(PurgeablePicture(decoding: try Self.image(), allocator: allocator))
    }

    /// A store of `count` pictures' bytes holding pictures "p0" (oldest) to "p<count-1>".
    private func filled(_ count: Int) throws -> HibernationSnapshots {
        let store = HibernationSnapshots(fullCapacityBytes: count * Self.pictureBytes)
        for index in 0..<count { store.insert(try picture(), for: "p\(index)") }
        return store
    }

    /// A larger decoded picture (feature `compressedSnapshots` off): its pixels are its cost.
    private func decoded() throws -> PurgeablePicture {
        try #require(PurgeablePicture(decoding: try Self.image(width: 32, height: 32), allocator: .resident))
    }

    private func release(_ store: HibernationSnapshots, to limit: MemoryLimit) -> MemoryReleaseProgress {
        store.releaseMemory(within: MemoryReleaseSlice(limit: limit) { false })
    }

    /// The app's hibernation sizes its store from the cache's shares: the fixed 64 MB with
    /// `memoryImageCaches` off (the test services' default), so no Mac's wake picture count moves.
    @Test func theHibernationTakesTheCachesSnapshotShare() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
        #expect(services.cache.imageCaches == .legacy)
        #expect(hibernation.snapshots.fullCapacityBytes == 64 << 20)
        // `purgeableImageCaches` off (the test services' default): the pictures stay resident.
        #expect(hibernation.snapshots.allocator.pages(byteCount: 16 << 10)?.isPurgeable == false)
    }

    @Test func aHalfLimitHalvesTheCapacityAndKeepsTheMostRecentPictures() throws {
        let store = try filled(8)
        store.updateMemoryLimit(MemoryLimit(percent: 50))
        #expect(store.capacityBytes == 4 * Self.pictureBytes, "a 50 % limit did not halve the capacity")
        #expect(store.count == 8, "the limit freed pictures before the release slice")
        #expect(release(store, to: MemoryLimit(percent: 50)) == .done)
        #expect(store.count == 4)
        #expect((4..<8).allSatisfy { store.image(for: "p\($0)") != nil }, "the release dropped one of the most recent pictures")
    }

    @Test func theCriticalLimitKeepsOnlyTheNeighborsPictures() throws {
        let store = try filled(6)
        store.neighbors = { ["p0", "p3"] }
        store.updateMemoryLimit(.criticalThreshold)
        #expect(release(store, to: .criticalThreshold) == .done)
        #expect(store.count == 2 && store.image(for: "p0") != nil && store.image(for: "p3") != nil,
                "the critical limit kept \(store.count) pictures, not only the neighbors'")
        store.insert(try picture(), for: "far")
        #expect(store.image(for: "far") == nil, "a picture of a tab beside no shown tab was kept at the critical limit")
        store.neighbors = { ["p0", "p3", "next"] }
        store.insert(try picture(), for: "next")
        #expect(store.image(for: "next") != nil, "a neighbor's new picture was dropped at the critical limit")
    }

    @Test func registersAsALossyExpensiveConsumerThatTheCoordinatorLeavesWholeAtWarning() throws {
        let traits = HibernationSnapshots.memoryTraits
        #expect(traits.isManaged && traits.retention == .lossy && traits.recreateCost == .expensive)
        #expect(MemoryReleaseOrder(traits: traits).tier == .lossy, "the pictures are not in the last release tier")
        #expect(MemoryLimitPolicy(mode: .aggressive).limit(for: traits, at: .warning) == .default)

        let kernel = ManualMemoryPressureSource()
        let pressure = MemoryPressureEvents(source: kernel)
        let slices = PreviewImageCacheTests.HeldSlices()
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slices)
        let store = try filled(4)
        store.neighbors = { ["p1"] }
        store.registerMemoryConsumer(with: coordinator)
        kernel.send(.warning)
        slices.runAll()
        #expect(store.count == 4, "warning dropped hibernation pictures")
        kernel.send(.critical)
        #expect(store.count == 4, "the critical limit freed pictures in the pressure event's turn")
        slices.runAll()
        #expect(store.count == 1 && store.image(for: "p1") != nil)
        #expect(store.memoryUsage == MemoryUsage(footprintBytes: Self.pictureBytes, entries: 1))
        withExtendedLifetime((pressure, coordinator)) {}
    }

    /// With compressed snapshots off the decoded pictures live in this store too, under the same neighbor
    /// rule: before, they sat in the terminal previews' LRU, which the critical limit emptied, neighbors too.
    @Test func decodedPicturesKeepTheNeighborRuleAtTheCriticalLimit() throws {
        let cost = try decoded().byteCount
        let store = HibernationSnapshots(fullCapacityBytes: 6 * cost)
        for index in 0..<6 { store.insert(try decoded(), for: "p\(index)") }
        #expect(store.count == 6 && store.totalBytes == 6 * cost, "decoded pictures were not kept in the store")
        store.neighbors = { ["p2"] }
        store.updateMemoryLimit(.criticalThreshold)
        #expect(release(store, to: .criticalThreshold) == .done)
        #expect(store.count == 1 && store.image(for: "p2") != nil, "the critical limit dropped a neighbor's decoded picture")
    }

    /// Under a lowered limit an insert drops only what the new picture needs; the drop to the limit is the
    /// coordinator's sliced release.
    @Test func anInsertUnderTheCriticalLimitEvictsOnlyWhatTheNewPictureNeeds() throws {
        let store = HibernationSnapshots(fullCapacityBytes: 8 * Self.pictureBytes)
        for index in 0..<6 { store.insert(try picture(), for: "p\(index)") }
        store.neighbors = { ["new"] }
        store.updateMemoryLimit(.criticalThreshold)
        store.insert(try picture(), for: "new")
        #expect(store.count == 6 && store.image(for: "p0") == nil && store.image(for: "new") != nil,
                "one insert dropped \(7 - store.count) pictures, more than the one it needed")
        #expect(release(store, to: .criticalThreshold) == .done)
        #expect(store.count == 1)
    }

    /// The critical limit captures no picture it would drop (an engine capture and an encode of up to
    /// 16 M pixels each): only a tab beside a shown tab is pictured.
    @Test func theCriticalLimitTakesNoPictureOfATabBesideNoShownTab() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
        let captures = CaptureCount()
        let image = try Self.image()
        hibernation.capture = { _ in
            captures.count += 1
            return image
        }
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        defer { tab.close() }
        let pane = PaneToken()
        hibernation.paneDidChange(ObjectIdentifier(pane), order: ["a", "b", "c", "d", "e"], selected: "a")
        hibernation.snapshots.updateMemoryLimit(.criticalThreshold)
        #expect(!hibernation.snapshots.keeps("c") && hibernation.snapshots.keeps("b"))
        #expect(await hibernation.snapshot(tab, key: "c") == nil)
        #expect(captures.count == 0, "the critical limit captured a picture it drops")
        #expect(await hibernation.snapshot(tab, key: "b") != nil, "a neighbor's picture was not taken at the critical limit")
        #expect(captures.count == 1)
        hibernation.snapshots.updateMemoryLimit(.default)
        #expect(await hibernation.snapshot(tab, key: "c") != nil)
        #expect(captures.count == 2)
        withExtendedLifetime(pane) {}
    }

    /// The real wiring: the hibernation's pane feed is the store's neighbors, radius 1 whatever the setting
    /// and the pressure, without panes whose window is off screen, and the critical limit through the
    /// coordinator keeps only those pictures.
    @Test func theHibernationKeepsItsShownTabsNeighborsPicturesAtTheCriticalLimit() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let kernel = ManualMemoryPressureSource()
        let pressure = MemoryPressureEvents(source: kernel)
        let slices = PreviewImageCacheTests.HeldSlices()
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slices)
        let hibernation = BrowserHibernation(cache: services.cache, memory: coordinator, deadlines: services.mainDeadlines)
        hibernation.apply(BrowserHibernationSetting(mode: .off, neighborRadius: 0))
        hibernation.snapshots.registerMemoryConsumer(with: coordinator)
        let (left, right) = (PaneToken(), PaneToken())
        hibernation.paneDidChange(ObjectIdentifier(left), order: ["l0", "l1", "l2", "l3", "l4", "l5"], selected: "l2")
        hibernation.paneDidChange(ObjectIdentifier(right), order: ["r0", "r1", "r2"], selected: "r0")
        hibernation.panesDidChangeScreen([ObjectIdentifier(right)], shownPages: [], offScreen: true)
        let hidden = ["l0", "l1", "l3", "l4", "l5", "r1", "r2"]
        for key in hidden { hibernation.snapshots.insert(try picture(), for: key) }
        #expect(hibernation.snapshots.count == hidden.count)

        kernel.send(.critical)
        slices.runAll()
        let kept = Set(hidden.filter { hibernation.snapshots.image(for: $0) != nil })
        #expect(kept == ["l1", "l3"], "the critical limit kept \(kept.sorted()), not the shown tab's two neighbors")
        withExtendedLifetime((pressure, coordinator, left, right)) {}
    }

    /// A picture the kernel purged, compressed or decoded, is a miss that leaves the store (the
    /// page wakes loading), never a blank wake; a neighbor's purged picture goes too, since nothing is left of it.
    @Test func aPurgedPictureIsAMissNotABlankWake() async throws {
        let fakes = FakePurgeableAllocations()
        let store = HibernationSnapshots(fullCapacityBytes: 64 << 20, allocator: fakes.allocator)
        store.insert(try #require(await HibernationSnapshots.compress(try Self.image(), allocator: store.allocator)), for: "compressed")
        store.insert(try #require(await HibernationSnapshots.decoded(try Self.image(), allocator: store.allocator)), for: "decoded")
        store.insert(try picture(allocator: store.allocator), for: "kept")
        store.neighbors = { ["decoded"] }
        let pages = fakes.pages
        try #require(pages.count == 3 && pages.allSatisfy(\.isVolatile), "kept pictures are not volatile at rest")
        let kept = try #require(store.image(for: "kept"))
        #expect(pages[0].purge() && pages[1].purge())
        #expect(store.image(for: "compressed") == nil, "a purged compressed picture was returned")
        #expect(store.image(for: "decoded") == nil, "a purged neighbor's picture was returned")
        #expect(store.count == 1 && store.totalBytes == Self.pictureBytes, "purged pictures stayed in the store")
        #expect(store.image(for: "kept") != nil)
        withExtendedLifetime(kept) {}
    }

    /// The report splits locked bytes (an image of the picture lives) from volatile ones.
    @Test func lockedAndVolatileBytesAreReportedApart() throws {
        let fakes = FakePurgeableAllocations()
        let store = HibernationSnapshots(fullCapacityBytes: 4 * Self.pictureBytes, allocator: fakes.allocator)
        for index in 0..<3 { store.insert(try picture(allocator: store.allocator), for: "p\(index)") }
        #expect(store.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 3 * Self.pictureBytes, entries: 3))
        try withExtendedLifetime(try #require(store.image(for: "p1"))) { _ in
            #expect(store.memoryUsage == MemoryUsage(footprintBytes: Self.pictureBytes, volatileBytes: 2 * Self.pictureBytes, entries: 3))
        }
        #expect(store.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 3 * Self.pictureBytes, entries: 3))
    }
}

/// Counts a hibernation's picture captures (its `capture` seam).
@MainActor private final class CaptureCount {
    var count = 0
}

/// A pane's identity in the hibernation's neighbor feed.
private final class PaneToken {}
