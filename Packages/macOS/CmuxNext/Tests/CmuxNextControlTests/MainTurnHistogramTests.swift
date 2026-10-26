@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// The main-turn and input-queueing histograms (p12-perf-process-031): Chrome-resolution buckets, a
/// percentile within one bucket of the true one, and the watchdog filling them from the stamps it already
/// takes. Heartbeats are driven by hand on an injected clock.
@Suite struct MainTurnHistogramTests {
    @Test func edgesRunFrom50MicrosecondsTo10SecondsAtMostTwentyPercentApart() {
        let edges = MainTurnHistogram.edgesNanos
        #expect(edges.first == 50_000)
        #expect(edges.last == 10_000_000_000)
        #expect((60...72).contains(edges.count))
        #expect(MainTurnHistogram.bucketCount == edges.count + 1)
        for (low, high) in zip(edges, edges.dropFirst()) {
            #expect(high > low)
            #expect(Double(high) / Double(low) <= 1.2 + 1e-4) // integer edges round by under 1 ns
        }
    }

    @Test func gapsOfTenPercentLandInDifferentBuckets() {
        #expect(MainTurnHistogram.bucket(forNanos: 3_600_000) != MainTurnHistogram.bucket(forNanos: 4_400_000))
        #expect(MainTurnHistogram.bucket(forNanos: 3_900_000) < MainTurnHistogram.bucket(forNanos: 4_400_000))
        let histogram = MainTurnHistogram()
        histogram.record(nanos: 3_600_000)
        histogram.record(nanos: 4_400_000)
        let counts = histogram.snapshot().counts
        #expect(counts.filter { $0 == 1 }.count == 2)
        #expect(counts.reduce(0, +) == 2)
    }

    @Test func underflowAndOverflowBuckets() {
        #expect(MainTurnHistogram.bucket(forNanos: 0) == 0)
        #expect(MainTurnHistogram.bucket(forNanos: 49_999) == 0)
        #expect(MainTurnHistogram.bucket(forNanos: 50_000) == 1)
        #expect(MainTurnHistogram.bucket(forNanos: 10_000_000_000) == MainTurnHistogram.bucketCount - 1)
        #expect(MainTurnHistogram.bucket(forNanos: .max) == MainTurnHistogram.bucketCount - 1)
        // Every edge starts its own bucket.
        for (index, edge) in MainTurnHistogram.edgesNanos.enumerated() {
            #expect(MainTurnHistogram.bucket(forNanos: edge) == index + 1)
            #expect(MainTurnHistogram.bucket(forNanos: edge - 1) == index)
        }
    }

    @Test func bucketPercentilesAreWithinTwentyPercentOfTheTruePercentiles() {
        // A long-tailed turn fixture: most turns 0.3-3 ms, some 4-20 ms, a few 50-400 ms.
        var generator = SplitMix64(seed: 0x031)
        var samples: [UInt64] = []
        for _ in 0..<20_000 {
            let roll = generator.unit()
            let range: (Double, Double) = roll < 0.9 ? (300_000, 3_000_000) : roll < 0.985 ? (4_000_000, 20_000_000) : (50_000_000, 400_000_000)
            samples.append(UInt64(range.0 * pow(range.1 / range.0, generator.unit())))
        }
        let histogram = MainTurnHistogram()
        for sample in samples { histogram.record(nanos: sample) }
        let snapshot = histogram.snapshot()
        let sorted = samples.sorted()
        #expect(snapshot.count == UInt64(samples.count))
        #expect(snapshot.maxNanos == sorted.last)
        for quantile in [0.5, 0.95, 0.99] {
            let truth = Double(sorted[Int((Double(sorted.count) * quantile).rounded(.up)) - 1])
            let estimate = Double(snapshot.percentile(quantile))
            #expect(abs(estimate - truth) / truth <= 0.2, "p\(quantile * 100): \(estimate) vs \(truth)")
        }
        #expect(snapshot.percentile(1) == sorted.last)
        #expect(MainTurnHistogram.Snapshot(counts: [UInt64](repeating: 0, count: MainTurnHistogram.bucketCount), maxNanos: 0)
            .percentile(0.99) == 0)
    }

    @Test func resetZeroesTheCountsAndTheMaximum() {
        let histogram = MainTurnHistogram()
        histogram.record(nanos: 12_000_000)
        histogram.record(nanos: 20_000_000_000)
        #expect(histogram.snapshot().maxNanos == 20_000_000_000)
        #expect(histogram.snapshot().counts.last == 1)
        histogram.reset()
        #expect(histogram.snapshot().count == 0)
        #expect(histogram.snapshot().maxNanos == 0)
    }

    /// A turn is a wake to the next sleep: the heartbeat counts it from the two stamps it took, and a sleep
    /// whose wake it never saw counts nothing.
    @MainActor
    @Test func theHeartbeatCountsEachTurnFromItsOwnStamps() {
        let clock = CountingUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false),
                                          uptime: clock.read)
        watchdog.mainAsleep.store(false, ordering: .releasing)
        clock.advance(by: 3_000_000)
        watchdog.heartbeat(.beforeWaiting) // no wake seen: not a turn
        #expect(watchdog.turnHistogram.snapshot().count == 0)
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: 1_000_000)
        watchdog.heartbeat(.beforeTimers)
        clock.advance(by: 2_600_000)
        watchdog.heartbeat(.beforeWaiting)
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: 4_400_000)
        watchdog.heartbeat(.beforeWaiting)
        let snapshot = watchdog.turnHistogram.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.counts[MainTurnHistogram.bucket(forNanos: 3_600_000)] == 1)
        #expect(snapshot.counts[MainTurnHistogram.bucket(forNanos: 4_400_000)] == 1)
        #expect(snapshot.maxNanos == 4_400_000)
        // One clock read per heartbeat: the histogram adds none.
        #expect(clock.reads == 6)
    }

    /// Queueing is the event's OS time to the last run-loop stamp before its dispatch; no clock is read.
    @MainActor
    @Test func inputQueueingRunsFromTheEventTimeToTheLastStamp() {
        let clock = CountingUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false),
                                          uptime: clock.read)
        let pressed = clock.now
        clock.advance(by: 6_000_000)
        watchdog.heartbeat(.afterWaiting)
        watchdog.heartbeat(.exit) // AppKit leaves the run loop to dispatch the event
        let readsBefore = clock.reads
        watchdog.noteInputDispatch(eventTimestamp: Double(pressed) / 1_000_000_000)
        // Posted inside the turn, after the last stamp: no queueing.
        watchdog.noteInputDispatch(eventTimestamp: Double(clock.now + 1_000_000) / 1_000_000_000)
        // No OS time, or not an uptime: nothing counted.
        watchdog.noteInputDispatch(eventTimestamp: 0)
        watchdog.noteInputDispatch(eventTimestamp: -1)
        watchdog.noteInputDispatch(eventTimestamp: .infinity)
        watchdog.noteInputDispatch(eventTimestamp: .nan)
        #expect(clock.reads == readsBefore)
        let snapshot = watchdog.inputQueueHistogram.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.counts[MainTurnHistogram.bucket(forNanos: 6_000_000)] == 1)
        #expect(snapshot.counts[0] == 1)
        #expect(watchdog.turnHistogram.snapshot().count == 0)
    }

    @MainActor
    @Test func debugHangsFieldsAndClear() {
        let clock = CountingUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false),
                                          uptime: clock.read)
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: 2_000_000)
        watchdog.heartbeat(.beforeWaiting)
        guard case .object(let fields) = watchdog.turnHistogramJSON,
              case .object(let turn) = fields["main_turn"],
              case .array(let edges) = fields["edges_us"],
              case .array(let buckets) = turn["buckets"] else {
            Issue.record("turn_histogram is not the expected object")
            return
        }
        #expect(edges.count == MainTurnHistogram.edgesNanos.count)
        #expect(buckets.count == MainTurnHistogram.bucketCount)
        #expect(turn["count"] == JSONValue.number(1))
        #expect(turn["max_ms"] == JSONValue.number(2))
        #expect(fields["input_queueing"] != nil)
        watchdog.resetTurnHistograms()
        #expect(watchdog.turnHistogram.snapshot().count == 0)
    }
}

/// An uptime clock (nanoseconds) that moves only when the test moves it and counts its reads.
private final class CountingUptime: Sendable {
    private let nanos = Atomic<UInt64>(1_000_000_000)
    private let readCount = Atomic<Int>(0)
    var now: UInt64 { nanos.load(ordering: .acquiring) }
    var reads: Int { readCount.load(ordering: .acquiring) }
    var read: @Sendable () -> UInt64 {
        { [self] in
            readCount.add(1, ordering: .relaxed)
            return nanos.load(ordering: .acquiring)
        }
    }
    func advance(by delta: UInt64) { nanos.add(delta, ordering: .releasing) }
}

/// A seeded generator, so the percentile fixture is the same on every run.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
    /// A uniform value in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
