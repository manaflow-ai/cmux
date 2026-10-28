@testable import CmuxNextMetrics
import CmuxNextTrace
import Testing

/// Chromium's own histograms in the app's store (p09-observability task 107): a harvested delta is kept on the heap in
/// Chromium's buckets, a report's delta lists it once, and the local view keeps every sample.
@Suite struct ChromiumHistogramFoldTests {
    private static func store(_ day: MetricsProfile.Day = MetricsProfile.Day(year: 2026, month: 10, day: 28)) -> MetricsStore {
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "7", channel: "test", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     buildDay: day)
        return MetricsStore(role: .app, profile: profile, pid: 4242, catalog: [.mainTurn])
    }

    private static let keyName = "chromium.EventLatency.KeyPressed.TotalLatency"

    @Test func aFoldedDeltaIsInTheNextReportOnceAndInTheLocalViewAlways() throws {
        let store = Self.store()
        #expect(store.foldChromium(.keyPressedLatency, count: 3, sum: 30_000,
                                   buckets: [.init(minimum: 8_000, count: 2), .init(minimum: 12_000, count: 1)]))
        let first = try #require(store.delta().histograms.first { $0.name == Self.keyName })
        #expect(first.layout == .chromium)
        #expect(first.count == 3 && first.sum == 30_000)
        #expect(first.buckets == [MetricsDelta.Bucket(index: 8_000, count: 2), MetricsDelta.Bucket(index: 12_000, count: 1)])

        store.markLogged(store.delta())
        #expect(store.delta().histograms.first { $0.name == Self.keyName } == nil, "a sent sample is never sent again")

        store.foldChromium(.keyPressedLatency, count: 1, sum: 9_000, buckets: [.init(minimum: 8_000, count: 1)])
        let second = try #require(store.delta().histograms.first { $0.name == Self.keyName })
        #expect(second.count == 1 && second.sum == 9_000 && second.buckets == [MetricsDelta.Bucket(index: 8_000, count: 1)])
        let totals = try #require(store.totals().histograms.first { $0.name == Self.keyName })
        #expect(totals.count == 4 && totals.buckets == [MetricsDelta.Bucket(index: 8_000, count: 3), MetricsDelta.Bucket(index: 12_000, count: 1)])
    }

    @Test func aPartOfADeltaMarkedSentLeavesTheRestForTheNextReport() throws {
        let store = Self.store()
        store.foldChromium(.droppedFrames, count: 5, sum: 25, buckets: [.init(minimum: 2, count: 3), .init(minimum: 10, count: 2)])
        let delta = store.delta()
        var part = delta
        part.histograms = delta.histograms.map { histogram in
            var cut = histogram
            cut.buckets = histogram.buckets.filter { $0.index == 2 }
            cut.count = 3
            cut.sum = 15
            return cut
        }
        store.markLogged(part)
        let rest = try #require(store.delta().histograms.first { $0.name == "chromium.Graphics.Smoothness.PercentDroppedFrames3.AllSequences" })
        #expect(rest.count == 2 && rest.sum == 10 && rest.buckets == [MetricsDelta.Bucket(index: 10, count: 2)])
    }

    @Test func anOwnHistogramOfTheSameDeltaIsMarkedAsBefore() {
        let runtime = TraceRuntime(role: .app)
        let store = Self.store()
        #expect(store.attach(to: runtime))
        Metrics(runtime: runtime).record(.mainTurn, 1_000)
        store.foldChromium(.gpuMemory, count: 1, sum: 80_000, buckets: [.init(minimum: 65_536, count: 1)])
        #expect(Set(store.delta().histograms.map(\.name)) == ["main.turn", "chromium.Memory.Gpu.PrivateMemoryFootprint"])
        store.markLogged(store.delta())
        #expect(store.delta().isEmpty)
    }

    @Test func anExpiredChromiumHistogramKeepsNothing() {
        let store = Self.store(MetricsProfile.Day(year: 2027, month: 5, day: 1))
        #expect(!store.foldChromium(.keyPressedLatency, count: 1, sum: 1, buckets: [.init(minimum: 0, count: 1)]))
        #expect(store.delta().isEmpty && store.totals().isEmpty)
    }
}
