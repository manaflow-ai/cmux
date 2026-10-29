import CmuxNextCompat
import CmuxNextResources
@testable import CmuxNextTabs
import CoreGraphics
import Foundation
import Testing

/// The tab hover card had its own kernel memory pressure source, which emptied its
/// thumbnails and samples at every warning, apart from the app's one pressure source. Now the
/// thumbnails and samples are one small, lossless memory consumer that the app's memory coordinator
/// limits: a new limit frees nothing, a release frees down to it least recently used first, and at
/// 0 % both caches are empty and it reports 0 bytes.
@MainActor @Suite struct TabHoverCardMemoryTests {
    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        var limit = MemoryLimit.default
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    private static let side = 32

    /// One 32 x 32 RGBA picture: `bytesPerRow * height` = 4,096 bytes.
    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    private static func report(_ id: TabID) -> ResourceReport {
        let usage = ResourceUsage(cpu: 0.01, memoryBytes: 64 << 20)
        return ResourceReport(tabs: [TabResourceReport(id: id.rawValue, title: "", kind: .terminal, usage: usage,
                                                       processCount: 1, sharedWithTabs: 0, available: true)],
                              total: usage, processCount: 1)
    }

    /// A controller holding `count` tabs' thumbnails and samples, tab 0 the oldest.
    private static func filled(_ count: Int, maxCount: Int = 24) throws -> TabHoverCardController {
        let controller = TabHoverCardController()
        controller.thumbnails = TabThumbnailCache(maxCount: maxCount, maxBytes: 48 << 20)
        var clock = Date(timeIntervalSince1970: 1_000)
        controller.now = { clock }
        for index in 0..<count {
            let tab = TabID("t\(index)")
            clock += 1
            controller.thumbnails.insert(PurgeablePicture(resident: try image()), for: tab)
            controller.rememberReport(report(tab), for: tab)
        }
        return controller
    }

    private static func slice(_ percent: Int, expired: Bool = false) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { expired }
    }

    @Test func traitsAreSmallLosslessAndCheap() {
        let traits = TabHoverCardController.memoryTraits
        #expect(traits.estimatedUsage == .small)
        #expect(traits.dataAccess == .none)
        #expect(traits.retention == .lossless)
        #expect(traits.recreateCost == .cheap)
        #expect(traits.isManaged)
    }

    @Test func usageCountsThumbnailPixelsAndEntries() throws {
        let controller = try Self.filled(3)
        let usage = try #require(controller.memoryUsage)
        #expect(usage.footprintBytes == 3 * Self.side * Self.side * 4)
        #expect(usage.volatileBytes == 0)
        #expect(usage.entries == 6)
    }

    @Test func aNewLimitFreesNothing() throws {
        let controller = try Self.filled(4)
        controller.updateMemoryLimit(MemoryLimit(percent: 0))
        #expect(controller.thumbnails.count == 4)
        #expect(controller.rememberedReportCount == 4)
    }

    @Test func releaseAtZeroEmptiesBothMapsAndReportsZeroBytes() throws {
        let controller = try Self.filled(5)
        #expect(controller.releaseMemory(within: Self.slice(0)) == .done)
        #expect(controller.thumbnails.count == 0)
        #expect(controller.rememberedReportCount == 0)
        #expect(controller.memoryUsage == MemoryUsage(footprintBytes: 0, entries: 0))
        // Held at 0 %, a later hover keeps nothing either.
        controller.thumbnails.insert(PurgeablePicture(resident: try Self.image()), for: TabID("late"))
        controller.rememberReport(Self.report(TabID("late")), for: TabID("late"))
        #expect(controller.memoryUsage == MemoryUsage(footprintBytes: 0, entries: 0))
    }

    @Test func releaseAtHalfKeepsTheMostRecentHalf() throws {
        let controller = try Self.filled(4, maxCount: 4)
        #expect(controller.releaseMemory(within: Self.slice(50)) == .done)
        #expect(controller.thumbnails.count == 2)
        #expect(controller.rememberedReportCount == 2)
        #expect(controller.thumbnails.image(for: TabID("t3")) != nil)
        #expect(controller.thumbnails.image(for: TabID("t2")) != nil)
        #expect(controller.thumbnails.image(for: TabID("t0")) == nil)
    }

    @Test func anExpiredSliceStopsAndAsksForMore() throws {
        let controller = try Self.filled(3)
        #expect(controller.releaseMemory(within: Self.slice(0, expired: true)) == .more)
        #expect(controller.thumbnails.count == 3)
    }

    @Test func limitsComeBackAtFullSize() throws {
        let controller = try Self.filled(2)
        _ = controller.releaseMemory(within: Self.slice(0))
        controller.updateMemoryLimit(.default)
        controller.thumbnails.insert(PurgeablePicture(resident: try Self.image()), for: TabID("back"))
        #expect(controller.thumbnails.count == 1)
    }

    @Test func theStripRegistersOneConsumerThatGetsTheLimitAtOnce() throws {
        let registry = FakeRegistry()
        registry.limit = MemoryLimit(percent: 0)
        let strip = TabStripView.testing(model: TabStripModel())
        strip.registerHoverCardMemory(with: registry)
        strip.registerHoverCardMemory(with: registry)
        #expect(registry.entries.count == 2)
        #expect(registry.entries.filter { $0.isLive }.count == 1, "a second registration replaces the first")
        #expect(registry.entries.last?.name == TabHoverCardController.memoryConsumerName)
        // The limit came with the registration: at 0 % a new thumbnail is not kept.
        strip.hoverCard.thumbnails.insert(PurgeablePicture(resident: try Self.image()), for: TabID("t"))
        #expect(strip.hoverCard.thumbnails.count == 0)
    }

    @Test func theConsumerLeavesTheRegistryWithItsController() {
        let registry = FakeRegistry()
        var controller: TabHoverCardController? = TabHoverCardController()
        if let controller {
            controller.memoryRegistration = MemoryConsumerRegistration(
                name: TabHoverCardController.memoryConsumerName, traits: TabHoverCardController.memoryTraits,
                consumer: controller, registry: registry)
        }
        #expect(registry.entries.first?.isLive == true)
        controller = nil
        #expect(registry.entries.first?.isLive == false)
    }
}
