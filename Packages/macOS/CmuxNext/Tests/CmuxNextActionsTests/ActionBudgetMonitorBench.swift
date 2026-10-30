import CmuxNextWakeups
import Foundation
@testable import CmuxNextActions
import Testing

/// The always-on cost of the per-action budget, in nanoseconds: what ``SignpostActionRunTiming``
/// adds to every run (two `CLOCK_UPTIME_RAW` reads and one
/// ``ActionBudgetMonitor/record(_:_:start:end:inputAgeMilliseconds:outcome:)`` with no reader),
/// and the hand-off of one batch to the reporter (one copy of ``ActionBudgetMonitor/batchSize``
/// runs and one yield, after a commit). A measurement, not a gate: run it in a Release build on
/// each macOS major and quote the line.
///
/// ```
/// CMUX_ACTION_BUDGET_BENCH=1 swift test -c release --filter ActionBudgetMonitorBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_ACTION_BUDGET_BENCH"] == "1"))
struct ActionBudgetMonitorBench {
    private static let runs = 2_000_000

    /// Nanoseconds per run of `runs` records into `monitor` (under budget, no sample reader).
    private static func recordNanos(_ monitor: ActionBudgetMonitor, _ indices: [UInt32]) -> Double {
        let start = ActionBudgetMonitor.now()
        for index in 0..<runs {
            monitor.record(indices[index & 3], .key, start: UInt64(index), end: UInt64(index) &+ 1_000,
                           inputAgeMilliseconds: 1.5, outcome: .committed)
        }
        return Double(ActionBudgetMonitor.now() - start) / Double(runs)
    }

    @Test func alwaysOnCostPerRunAndPerBatch() async {
        let ids: [ActionID] = ["splitRight", "palette.toggleWorkspacePin", "newTab", "closeTab"]

        var clockSink: UInt64 = 0
        let clockStart = ActionBudgetMonitor.now()
        for _ in 0..<Self.runs { clockSink &+= ActionBudgetMonitor.now() }
        let clockNanos = Double(ActionBudgetMonitor.now() - clockStart) / Double(Self.runs)

        // No batch reader: the ring write and the counters only.
        let bare = ActionBudgetMonitor()
        let bareIndices = ids.map(bare.intern)
        _ = Self.recordNanos(bare, bareIndices)  // warm
        let perRun = Self.recordNanos(bare, bareIndices)

        // With the reporter's batch reader draining off the main actor.
        let batched = ActionBudgetMonitor()
        let batchedIndices = ids.map(batched.intern)
        let batches = batched.batches()
        let drain = Task.detached { var runs = 0; for await batch in batches { runs += batch.count }; return runs }
        let withBatches = Self.recordNanos(batched, batchedIndices)
        let batchCount = Double(Self.runs / batched.batchSize)
        let perBatch = (withBatches - perRun) * Double(Self.runs) / batchCount
        drain.cancel()

        // With the app's board attached: the span's begin and end (atomics) on every run, as in the app.
        let board = MainTaskBoard()
        let spanned = ActionBudgetMonitor(board: board)
        let spannedIndices = ids.map(spanned.intern)
        let spanStart = ActionBudgetMonitor.now()
        for index in 0..<Self.runs {
            let start = UInt64(index)
            let span = spanned.beginSpan(spannedIndices[index & 3], start: start)
            spanned.record(spannedIndices[index & 3], .key, start: start, end: start &+ 1_000, inputAgeMilliseconds: 1.5,
                           outcome: .committed, span: span)
        }
        let withSpan = Double(ActionBudgetMonitor.now() - spanStart) / Double(Self.runs)
        print(String(format: "action-budget bench: with the board span: %.1f ns/run (record + span begin and end)", withSpan))

        let line = String(format: "action-budget bench: macOS %@, %d runs: record %.1f ns/run, clock read %.1f ns, always-on %.1f ns/run; "
                          + "batch hand-off %.0f ns per %d runs (%.1f ns/run amortized, %llu runs dropped) (sink %llu)",
                          ProcessInfo.processInfo.operatingSystemVersionString, Self.runs, perRun, clockNanos, perRun + 2 * clockNanos,
                          perBatch, batched.batchSize, withBatches - perRun, batched.droppedRunCount, clockSink & 1)
        print(line)
        #expect(bare.runCount == UInt64(2 * Self.runs))
    }
}
