import CmuxNextCompat
import CmuxNextMemory
import Foundation
import Testing

/// Bucketed local histograms (Chrome's `base::Histogram` layouts), hours closed by
/// the next event or read with no timer, empty hours recorded in one step, minutes at the applied
/// level per hour, WARN deliveries per hour, discards per hour by kind, wake latency and footprints.
@MainActor @Suite struct MemoryHistogramTests {
    /// A clock the test moves.
    final class Clock {
        var now: Duration = .zero
    }

    private static let kinds = ["browser", "agent_page"]

    private func make(_ clock: Clock, source: ManualMemoryPressureSource = ManualMemoryPressureSource())
        -> (MemoryHistograms, MemoryPressureEvents, ManualMemoryPressureSource) {
        let events = MemoryPressureEvents(source: source)
        return (MemoryHistograms(pressure: events, discardKinds: Self.kinds, elapsed: { clock.now }), events, source)
    }

    @Test func exponentialLayoutIsChromesShape() {
        let layout = MemoryHistogram.Layout.exponential(minimum: 1, maximum: 64_000, bucketCount: 100)
        #expect(layout.lowerBounds.count == 100)
        #expect(layout.lowerBounds.prefix(4) == [0, 1, 2, 3])
        #expect(layout.lowerBounds.last == 64_000)
        #expect(zip(layout.lowerBounds, layout.lowerBounds.dropFirst()).allSatisfy { $0 < $1 })
        #expect(MemoryHistogram.Layout.perHour.lowerBounds.last == 1_000)
        #expect(MemoryHistogram.Layout.minutesOfHour.lowerBounds == Array(stride(from: 0, through: 60, by: 5)))
    }

    @Test func recordsIntoBucketsOnly() throws {
        var histogram = MemoryHistogram(layout: .minutesOfHour)
        histogram.record(0)
        histogram.record(7)
        histogram.record(9)
        histogram.record(60, times: 3)
        histogram.record(500)
        histogram.record(-4)
        #expect(histogram.count == 8)
        #expect(histogram.sum == 0 + 7 + 9 + 180 + 500 + 0)
        #expect(histogram.buckets == [
            .init(min: 0, max: 5, count: 2), .init(min: 5, max: 10, count: 2), .init(min: 60, max: nil, count: 4),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: encoder.encode(histogram), encoding: .utf8))
        #expect(json.contains(#"{"count":4,"max":null,"min":60}"#))
        #expect(!json.contains("7"), "no sample is kept, only bucket counts")
    }

    @Test func bucketSearchMatchesALinearScan() {
        let layout = MemoryHistogram.Layout.footprintMiB
        for value in [0, 1, 2, 99, 100, 101, 1_023, 4_096, 63_999, 64_000, 1 << 30] {
            let scanned = layout.lowerBounds.lastIndex { $0 <= value } ?? 0
            #expect(layout.bucket(of: value) == scanned, "\(value)")
        }
    }

    /// Discards in the open hour are in no histogram until the hour ends; an event hours later
    /// closes that hour and records the empty hours between in one step.
    @Test func discardsPerHourCloseOnTheNextEvent() {
        let clock = Clock()
        let (histograms, _, _) = make(clock)
        for _ in 0 ..< 3 { histograms.recordDiscard(kind: "browser") }
        histograms.recordDiscard(kind: "agent_page")
        histograms.recordDiscard(kind: "not_a_kind")
        #expect(histograms.snapshot().hours == 0)
        #expect(histograms.snapshot().discardsPerHour["browser"]?.count == 0)

        clock.now = .seconds(3 * 3_600 + 1_800)
        histograms.recordDiscard(kind: "browser")
        let snapshot = histograms.snapshot()
        #expect(snapshot.hours == 3)
        #expect(snapshot.discardsPerHour["browser"]?.buckets == [.init(min: 0, max: 1, count: 2), .init(min: 3, max: 4, count: 1)])
        #expect(snapshot.discardsPerHour["agent_page"]?.buckets == [.init(min: 0, max: 1, count: 2), .init(min: 1, max: 2, count: 1)])
        #expect(snapshot.discardsPerHour["not_a_kind"] == nil)

        clock.now = .seconds(4 * 3_600)
        #expect(histograms.snapshot().discardsPerHour["browser"]?.sum == 4, "the fourth hour's discard counts once it ends")
    }

    /// Minutes at the applied level per hour, split at the hour ends, whole hours at a level as 60;
    /// every kernel WARN delivery counts, a repeated one too.
    @Test func minutesAtLevelAndWarnEventsPerHour() {
        let clock = Clock()
        let (histograms, _, source) = make(clock)
        clock.now = .seconds(30 * 60)
        source.send(.warning)
        clock.now = .seconds(40 * 60)
        source.send(.warning)
        clock.now = .seconds(45 * 60)
        source.send(.normal)
        clock.now = .seconds(110 * 60)
        source.send(.critical)
        clock.now = .seconds(250 * 60)
        let snapshot = histograms.snapshot()

        #expect(snapshot.hours == 4)
        // Hour 0: 15 min at warning; hours 1 to 3: none.
        #expect(snapshot.warningMinutesPerHour.buckets == [.init(min: 0, max: 5, count: 3), .init(min: 15, max: 20, count: 1)])
        // Hour 1: 10 min at critical; hours 2 and 3: the whole hour.
        #expect(snapshot.criticalMinutesPerHour.buckets == [
            .init(min: 0, max: 5, count: 1), .init(min: 10, max: 15, count: 1), .init(min: 60, max: nil, count: 2),
        ])
        #expect(snapshot.warnEventsPerHour.buckets == [.init(min: 0, max: 1, count: 3), .init(min: 2, max: 3, count: 1)])
    }

    /// The override is the applied level for the minutes; a kernel change under it does not change
    /// the applied level. No level change samples a footprint (the app's emitter does, once an hour).
    @Test func theOverrideIsTheAppliedLevel() {
        let clock = Clock()
        let (histograms, _, source) = make(clock)
        histograms.overrideDidChange(.critical)
        clock.now = .seconds(20 * 60)
        source.send(.warning)
        histograms.overrideDidChange(.critical)
        clock.now = .seconds(50 * 60)
        histograms.overrideDidChange(nil)
        clock.now = .seconds(60 * 60)
        let snapshot = histograms.snapshot()

        #expect(snapshot.appFootprintMiB.count == 0, "a pressure change sampled a footprint")
        #expect(snapshot.criticalMinutesPerHour.buckets == [.init(min: 50, max: 55, count: 1)])
        #expect(snapshot.warningMinutesPerHour.buckets == [.init(min: 10, max: 15, count: 1)])
        #expect(snapshot.warnEventsPerHour.sum == 1)
    }

    /// A read closes the ended hours and records nothing else: reading every ten minutes and reading
    /// once give the same histograms.
    @Test func readsRecordNothing() {
        let clock = Clock()
        let (polled, _, _) = make(clock)
        let (readOnce, _, _) = make(clock)
        polled.recordDiscard(kind: "browser")
        readOnce.recordDiscard(kind: "browser")
        for minute in stride(from: 0, through: 150, by: 10) {
            clock.now = .seconds(minute * 60)
            _ = polled.snapshot()
        }
        #expect(polled.snapshot() == readOnce.snapshot())
        #expect(polled.snapshot().appFootprintMiB.count == 0)
        #expect(polled.snapshot().hours == 2)
    }

    @Test func footprintsAndWakes() {
        let (histograms, _, _) = make(Clock())
        histograms.recordFootprints(MemoryDiagnosticsProcesses(rows: [
            .init(kind: .app, pid: 1, physFootprintBytes: 361 << 20),
            .init(kind: .chromiumRenderer, pid: 2, physFootprintBytes: 60 << 20),
            .init(kind: .webkitWebContent, pid: 3, physFootprintBytes: 40 << 20),
            .init(kind: .webkitWebContent, pid: 4, physFootprintBytes: nil),
            .init(kind: .chromiumGPU, pid: 5, physFootprintBytes: 500 << 20),
        ]))
        histograms.recordFootprints(MemoryDiagnosticsProcesses(rows: [.init(kind: .app, pid: 1, physFootprintBytes: nil)]))
        histograms.recordWake(.milliseconds(240))
        let snapshot = histograms.snapshot()

        #expect(snapshot.appFootprintMiB.count == 1, "an unknown footprint is no sample")
        #expect(snapshot.appFootprintMiB.sum == 361)
        #expect(snapshot.rendererFootprintMiB.count == 1)
        #expect(snapshot.rendererFootprintMiB.sum == 100, "renderers only, the GPU process left out")
        #expect(snapshot.wakeMilliseconds.sum == 240)
    }

    @Test func snapshotEncodesTheSchemaKeys() throws {
        let (histograms, _, _) = make(Clock())
        let data = try JSONEncoder().encode(histograms.snapshot())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "hours", "app_pmf_mb", "renderer_pmf_mb", "wake_latency_ms", "discards_per_hour", "warning_minutes_per_hour",
            "critical_minutes_per_hour", "warn_events_per_hour",
        ])
        let discards = try #require(object["discards_per_hour"] as? [String: Any])
        #expect(Set(discards.keys) == Set(Self.kinds))
    }
}
