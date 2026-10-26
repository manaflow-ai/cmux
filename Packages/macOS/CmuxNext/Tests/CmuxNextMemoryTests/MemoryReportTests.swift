import CmuxNextCompat
import CmuxNextMemory
import Foundation
import Testing

struct MemoryReportTests {
    nonisolated static let cheapCache = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)
    nonisolated static let pagePlanner = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .reads, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .high, isStateful: false, supportsMemoryLimit: false)
    nonisolated static let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: true)

    nonisolated static func sample() -> MemoryReport {
        MemoryReport(
            level: .warning,
            mode: .medium,
            budget: budget,
            consumers: [
                MemoryReport.Consumer(
                    name: "image-cache", traits: cheapCache, limit: MemoryLimit(percent: 25),
                    footprintBytes: 33_554_432, volatileBytes: 0, entries: 412),
                MemoryReport.Consumer(
                    name: "browser-pages", traits: pagePlanner, limit: .default,
                    footprintBytes: nil, volatileBytes: nil, entries: 3),
            ]
        )
    }

    @Test func codableRoundTripKeepsEveryField() throws {
        let report = Self.sample()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MemoryReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.budget.imageCacheBytes == 128 << 20)
        #expect(decoded.consumers[1].footprintBytes == nil)
    }

    @Test func unknownBytesEncodeAsNullNotZero() throws {
        let data = try JSONEncoder().encode(Self.sample())
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        let consumers = try #require(json["consumers"] as? [[String: Any]])
        let pages = consumers[1]
        #expect(pages["footprint_bytes"] is NSNull)
        #expect(pages["volatile_bytes"] is NSNull)
        #expect(pages["entries"] as? Int == 3)
        #expect(consumers[0]["volatile_bytes"] as? Int == 0)
        #expect(json["level"] as? String == "warning")
        #expect(json["mode"] as? String == "medium")
    }

    @Test func missingCountDecodesAsUnknown() throws {
        let json = #"""
            {"name":"x","limit":100,"traits":{"estimatedUsage":"small","dataAccess":"none",
            "retention":"lossless","recreateCost":"cheap","releaseCPUCost":"low",
            "isStateful":true,"supportsMemoryLimit":true}}
            """#
        let consumer = try JSONDecoder().decode(MemoryReport.Consumer.self, from: Data(json.utf8))
        #expect(consumer.footprintBytes == nil)
        #expect(consumer.volatileBytes == nil)
        #expect(consumer.entries == nil)
    }

    @Test func textShowsUnknownForNilBytes() {
        let lines = Self.sample().description.split(separator: "\n").map(String.init)
        #expect(lines == [
            "level warning, mode medium, 2 consumers",
            "image-cache: footprint 33554432 B, volatile 0 B, entries 412, limit 25 %",
            "browser-pages: footprint unknown B, volatile unknown B, entries 3, limit 100 %",
        ])
    }

    @Test func budgetRoundTripsEveryField() throws {
        let data = try JSONEncoder().encode(Self.budget)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        #expect(json["physical_mib"] as? Int == 16_384)
        #expect(json["chromium_renderer_limit"] as? Int == 64)
        #expect(json["parked_idle_timeout_seconds"] as? Int == 900)
        let decoded = try JSONDecoder().decode(SubsystemBudget.self, from: data)
        #expect(decoded == Self.budget)
    }

    @Test func budgetDecodesTheFieldsItHoldsNotItsFormulas() throws {
        // A report from a build whose formulas differ: the decoded budget is what that build had.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.budget))
        var json = try #require(object as? [String: Any])
        json["chromium_renderer_limit"] = 10
        json["parked_idle_timeout_seconds"] = 60
        let decoded = try JSONDecoder().decode(SubsystemBudget.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.physicalMiB == 16_384)
        #expect(decoded.chromiumRendererLimit == 10)
        #expect(decoded.parkedIdleTimeout == .seconds(60))
        #expect(decoded.imageCacheBytes == Self.budget.imageCacheBytes)
    }

    @MainActor @Test func coordinatorReportsEachLiveConsumerOnceWithItsLimit() {
        let source = ManualMemoryPressureSource(initial: .normal)
        let clock = ManualClock()
        let pressure = MemoryPressureEvents(source: source)
        let coordinator = MemoryCoordinator(
            pressure: pressure, mode: .aggressive, slicer: ManualSlicer(clock: clock), clock: clock)
        let pages = CountingConsumer(usage: nil)
        let images = CountingConsumer(usage: MemoryUsage(footprintBytes: 4096, volatileBytes: 1024, entries: 2))
        let gone = CountingConsumer(usage: .empty)
        // The lossy planner registers first; the report lists release order, so the cheap cache leads.
        let pagesRegistration = MemoryConsumerRegistration(
            name: "pages", traits: Self.pagePlanner, consumer: pages, registry: coordinator)
        let imagesRegistration = MemoryConsumerRegistration(
            name: "images", traits: Self.cheapCache, consumer: images, registry: coordinator)
        let goneRegistration = MemoryConsumerRegistration(
            name: "gone", traits: Self.cheapCache, consumer: gone, registry: coordinator)
        goneRegistration.cancel()
        coordinator.pressureOverride = .warning
        coordinator.mode = .medium

        let report = coordinator.report(budget: Self.budget)

        #expect(report.level == .warning)
        #expect(report.mode == .medium)
        #expect(report.budget == Self.budget)
        #expect(coordinator.limit(for: Self.cheapCache) == MemoryLimit(percent: 25))
        #expect(report.consumers == [
            MemoryReport.Consumer(
                name: "images", traits: Self.cheapCache, limit: coordinator.limit(for: Self.cheapCache),
                footprintBytes: 4096, volatileBytes: 1024, entries: 2),
            MemoryReport.Consumer(
                name: "pages", traits: Self.pagePlanner, limit: coordinator.limit(for: Self.pagePlanner),
                footprintBytes: nil, volatileBytes: nil, entries: nil),
        ])
        #expect(images.usageReads == 1)
        #expect(pages.usageReads == 1)
        #expect(gone.usageReads == 0)
        withExtendedLifetime((pressure, pagesRegistration, imagesRegistration)) {}
    }
}

/// A consumer with a fixed usage that counts how often the report reads it.
@MainActor
private final class CountingConsumer: MemoryConsumer {
    private let usage: MemoryUsage?
    private(set) var usageReads = 0

    init(usage: MemoryUsage?) {
        self.usage = usage
    }

    func updateMemoryLimit(_ limit: MemoryLimit) {}

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        .done
    }

    var memoryUsage: MemoryUsage? {
        usageReads += 1
        return usage
    }
}
