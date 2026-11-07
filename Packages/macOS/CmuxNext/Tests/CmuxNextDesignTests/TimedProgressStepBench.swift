import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The cost of one `TimedProgress.motionStep` frame (perf-hot, motion-frame: 4 ms), in nanoseconds a step,
/// as p50 / p95 / p99 over batches of steps (CMUX_PANE_BENCH=1, beside PaneMotionBench). Each batch starts a
/// run and steps it 1,000 times at 120 Hz without reaching its end, timing the batch, so the clock's own
/// read stays out of the per-step figure. A bench, not a gate: run it yourself before and after a change
/// to the step (`cmux-ci run --class light --script scripts/ci/package-test-lane.sh --arg=suite
/// --arg=Packages/macOS/CmuxNext --arg=TimedProgressStepBench --env CMUX_PANE_BENCH=1
/// --env CMUX_SWIFT_SUITE_CONFIGURATION=release`).
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct TimedProgressStepBench {
    static let batches = 2_000
    static let steps = 1_000

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Nanoseconds a step, one value per batch; `start` begins each batch's run.
    static func measure(_ start: (TimedProgress, NSView) -> Void) -> [Double] {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var sink = 0.0
        let progress = TimedProgress { sink += $0 }
        var perStep: [Double] = []
        perStep.reserveCapacity(batches)
        for _ in 0..<batches {
            start(progress, view)
            let begin = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<steps { _ = progress.motionStep(1.0 / 120) }
            perStep.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / Double(steps))
            progress.stop()
        }
        #expect(sink > 0)
        return perStep
    }

    static func report(_ name: String, _ values: [Double]) {
        let format = { (value: Double) in String(format: "%.2f", value) }
        print("TIMED-PROGRESS-BENCH curve=\(name) batches=\(values.count) steps=\(steps) p50_ns=\(format(percentile(values, 0.5))) p95_ns=\(format(percentile(values, 0.95))) p99_ns=\(format(percentile(values, 0.99))) max_ns=\(format(values.max() ?? 0))")
    }

    /// The default ease-out (the sidebar width's run): the same call before and after a change.
    @Test func defaultCurveStep() {
        let values = Self.measure { progress, view in progress.run(duration: 100, in: view, trace: "bench.timed") }
        Self.report("default", values)
        #expect(Self.percentile(values, 0.99) < 4_000_000, "a step over the 4 ms motion-frame budget")
    }

    /// The settle (Session Info's folds).
    @Test func settleCurveStep() {
        let values = Self.measure { progress, view in progress.run(duration: 100, curve: .settle, in: view, trace: "bench.settle") }
        Self.report("settle", values)
        #expect(Self.percentile(values, 0.99) < 4_000_000, "a step over the 4 ms motion-frame budget")
    }
}
