import CmuxNextTestSupport
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The always-on cost of ``MainTurnMeter`` per main run-loop turn, in nanoseconds: one top-level turn
/// with its observer callouts (entry, wake, the exit to dispatch an event and its commit, the
/// before-waiting phase), one `sendEvent` input span and one scheduled task's span, on the real
/// `CLOCK_UPTIME_RAW` clock. The budget is < 100 ns per turn over the clock reads
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task 008). A measurement, not a gate: run it in
/// a Release build on each macOS major and quote the line (perf-hot path `main-turn`). With
/// CMUX_PERF_RESULT_DIR it also writes each number as result-v1 (lab story swift-main-turn).
///
/// ```
/// CMUX_MAIN_TURN_BENCH=1 swift test -c release --filter MainTurnMeterBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_MAIN_TURN_BENCH"] == "1"))
struct MainTurnMeterBench {
    private static let turns = 1_000_000
    /// The clock reads one turn makes: one per observer callout (6), two for the input span, and the
    /// task span's two (the budget's own reads in the app).
    private static let readsPerTurn = 10

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Nanoseconds per turn over `turns` turns on `meter`, whose run loop is entered: AppKit's pattern,
    /// wake, a task, the exit to dispatch an event, the entry again and the before-waiting phase.
    private static func turnNanos(_ meter: MainTurnMeter) -> Double {
        let start = now()
        for _ in 0..<turns {
            meter.loopWoke()
            meter.beginSpan(.scheduled, at: now())
            meter.endTask(at: now(), ownNanos: 1_000)
            meter.loopWillExit()
            meter.loopExited()
            meter.inputDispatch {}
            meter.loopEntered()
            meter.loopWillWait()
            meter.loopDidRender()
        }
        return Double(now() - start) / Double(turns)
    }

    @Test func alwaysOnCostPerTurn() throws {
        var clockSink: UInt64 = 0
        let clockStart = Self.now()
        for _ in 0..<Self.turns { clockSink &+= Self.now() }
        let clockNanos = Double(Self.now() - clockStart) / Double(Self.turns)

        let meter = MainTurnMeter()
        meter.loopEntered()
        _ = Self.turnNanos(meter)  // warm
        meter.reset()
        let perTurn = Self.turnNanos(meter)
        let reads = Double(Self.readsPerTurn)
        let line = String(format: "main-turn bench: macOS %@, %d turns: %.1f ns/turn, clock read %.1f ns, %.1f ns/turn over %.0f clock reads (sink %llu)",
                          ProcessInfo.processInfo.operatingSystemVersionString, Self.turns, perTurn, clockNanos,
                          perTurn - reads * clockNanos, reads, clockSink & 1)
        print(line)
        if let results = try PerfResultWriter() {
            try results.record("swift.main_turn.turn_ns", unit: .ns, samples: [perTurn])
            try results.record("swift.main_turn.clock_read_ns", unit: .ns, samples: [clockNanos])
            try results.record("swift.main_turn.over_clock_reads_ns", unit: .ns, samples: [perTurn - reads * clockNanos])
        }
        #expect(meter.snapshot().turns == Self.turns)
        #expect(meter.snapshot().tasks == Self.turns)
    }
}
