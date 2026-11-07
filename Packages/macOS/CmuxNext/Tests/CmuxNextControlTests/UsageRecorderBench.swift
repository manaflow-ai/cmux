import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextControl
import Foundation
import Testing

/// What opt-in usage recording adds to a settled focus change, in nanoseconds: the call the
/// focus settle makes (``UsageRecorder/noteFocus(appActive:windowKey:kind:tab:)``) while
/// recording is off, on with the same place (the common case: a settle that moved nothing the
/// recorder keeps), and on with a new place every call (one event staged under the queue's lock;
/// a batch of 64 hands one send to a task). The baseline is an empty loop of the same shape, which
/// is what the settle did before. A measurement, not a gate.
///
/// ```
/// CMUX_USAGE_BENCH=1 swift test -c release --filter UsageRecorderBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_USAGE_BENCH"] == "1"))
struct UsageRecorderBench {
    private static let calls = 1_000_000

    private static func nanos(_ body: (Int) -> Void) -> Double {
        let start = ActionBudgetMonitor.now()
        for index in 0..<calls { body(index) }
        return Double(ActionBudgetMonitor.now() - start) / Double(calls)
    }

    private static func recorder() -> UsageRecorder {
        let ports = UsageRecorder.Ports(
            channel: "dev", build: "1", previousRun: { "clean" }, counts: { UsageCounts() }, appActive: { true },
            ask: { _, _, _, _ in false }, setEnabled: { _ in }, record: { _, _ in })
        return UsageRecorder(ports: ports, managedDisables: { false },
                             defaults: UserDefaults(suiteName: "cn-usage-bench-\(UUID().uuidString)") ?? .standard)
    }

    @Test func focusSettleCost() async {
        var sink = 0
        let baseline = Self.nanos { sink &+= $0 & 1 }

        let off = Self.recorder()
        let offNanos = Self.nanos { _ in
            if off.isRecording { off.noteFocus(appActive: true, windowKey: true, kind: "terminal", tab: "t") }
        }

        let on = Self.recorder()
        on.apply(true)
        let sameNanos = Self.nanos { _ in
            if on.isRecording { on.noteFocus(appActive: true, windowKey: true, kind: "terminal", tab: "t") }
        }
        let tabs = ["a", "b", "c", "d"]
        let movingNanos = Self.nanos { index in
            if on.isRecording { on.noteFocus(appActive: true, windowKey: true, kind: "agentPage", tab: tabs[index & 3]) }
        }
        on.apply(false)

        print(String(format: "usage-recording bench: macOS %@, %d calls: baseline %.1f ns, off %.1f ns, on (same place) %.1f ns, "
                     + "on (new place each call) %.1f ns per focus settle (sink %d)",
                     ProcessInfo.processInfo.operatingSystemVersionString, Self.calls, baseline, offNanos, sameNanos, movingNanos, sink & 1))
        #expect(!on.isRecording)
    }
}
