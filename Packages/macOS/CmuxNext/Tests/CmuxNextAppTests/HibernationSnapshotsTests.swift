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
/// follow the memory coordinator as a lossy consumer (p07-memory-058): a limit scales the bytes kept, the
/// pictures of the tabs beside a shown tab stay at any limit, and the critical limit keeps only those,
/// compressed or decoded, and takes no picture it would drop.
@MainActor @Suite(.serialized)
struct HibernationSnapshotsTests {
    private static let pictureBytes = 1_000

    private func picture() throws -> HibernationSnapshots.Picture {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return HibernationSnapshots.Picture(data: Data(count: Self.pictureBytes), image: try #require(context.makeImage()))
    }

    /// A store of `count` pictures' bytes holding pictures "p0" (oldest) to "p<count-1>".
    private func filled(_ count: Int) throws -> HibernationSnapshots {
        let store = HibernationSnapshots(fullCapacityBytes: count * Self.pictureBytes)
        for index in 0..<count { store.insert(try picture(), for: "p\(index)") }
        return store
    }

    /// A decoded picture (feature `compressedSnapshots` off): no bytes, its pixels are its cost.
    private func decoded() throws -> HibernationSnapshots.Picture {
        HibernationSnapshots.Picture(data: nil, image: try picture().image)
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
        let cost = try decoded().cost
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
        let image = try picture().image
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
}

/// Counts a hibernation's picture captures (its `capture` seam).
@MainActor private final class CaptureCount {
    var count = 0
}

/// A pane's identity in the hibernation's neighbor feed.
private final class PaneToken {}
