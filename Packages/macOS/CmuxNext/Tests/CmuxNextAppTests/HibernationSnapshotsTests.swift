@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextMemory
import CoreGraphics
import Foundation
import Testing

/// Hibernated pages' pictures are sized from `SubsystemBudget.hibernationSnapshotBytes` and follow the
/// memory coordinator as a lossy consumer (p07-memory-058): a limit scales the bytes kept, the pictures
/// of the tabs beside a shown tab stay at any limit, and the critical limit keeps only those.
@MainActor @Suite
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

    private func release(_ store: HibernationSnapshots, to limit: MemoryLimit) -> MemoryReleaseProgress {
        store.releaseMemory(within: MemoryReleaseSlice(limit: limit) { false })
    }

    @Test func theStoreTakesTheHibernationSnapshotBudget() {
        let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)
        let store = HibernationSnapshots(budget: budget)
        #expect(store.fullCapacityBytes == budget.hibernationSnapshotBytes)
        #expect(store.fullCapacityBytes >= 64 << 20, "a 16 GB Mac's snapshot store is under the old 64 MB")
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
}
