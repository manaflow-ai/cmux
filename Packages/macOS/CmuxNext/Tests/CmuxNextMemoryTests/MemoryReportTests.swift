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

    @Test func budgetEncodesItsFieldsAndDecodesFromItsInputs() throws {
        let data = try JSONEncoder().encode(Self.budget)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        #expect(json["physical_mib"] as? Int == 16_384)
        #expect(json["chromium_renderer_limit"] as? Int == 64)
        #expect(json["parked_idle_timeout_seconds"] as? Int == 900)
        let decoded = try JSONDecoder().decode(SubsystemBudget.self, from: data)
        #expect(decoded == Self.budget)
    }

    @Test func entriesReportEachLiveConsumerOnceWithItsLimit() {
        let registry = RecordingRegistry()
        let images = CountingConsumer(usage: MemoryUsage(footprintBytes: 4096, volatileBytes: 1024, entries: 2))
        let unknown = CountingConsumer(usage: nil)
        let gone = CountingConsumer(usage: .empty)
        let imagesRegistration = MemoryConsumerRegistration(
            name: "images", traits: Self.cheapCache, consumer: images, registry: registry)
        let unknownRegistration = MemoryConsumerRegistration(
            name: "pages", traits: Self.pagePlanner, consumer: unknown, registry: registry)
        let goneRegistration = MemoryConsumerRegistration(
            name: "gone", traits: Self.cheapCache, consumer: gone, registry: registry)
        goneRegistration.cancel()

        let report = MemoryReport(
            level: .critical, mode: .aggressive, budget: Self.budget, entries: registry.consumers.liveEntries()
        ) { traits in traits.isManaged ? MemoryLimit(percent: 0) : .default }

        #expect(report.consumers == [
            MemoryReport.Consumer(
                name: "images", traits: Self.cheapCache, limit: MemoryLimit(percent: 0),
                footprintBytes: 4096, volatileBytes: 1024, entries: 2),
            MemoryReport.Consumer(
                name: "pages", traits: Self.pagePlanner, limit: .default,
                footprintBytes: nil, volatileBytes: nil, entries: nil),
        ])
        #expect(images.usageReads == 1)
        #expect(unknown.usageReads == 1)
        #expect(gone.usageReads == 0)
        withExtendedLifetime((imagesRegistration, unknownRegistration)) {}
    }
}

/// A registry that keeps entries as the coordinator does and hands each one the default limit.
private final class RecordingRegistry: MemoryConsumerRegistry {
    var consumers = MemoryConsumerList()

    func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
        consumers.add(entry)
        entry.liveConsumer?.updateMemoryLimit(.default)
    }
}

/// A consumer with a fixed usage that counts how often the report reads it.
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
