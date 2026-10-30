import CmuxNextWakeups
import Foundation

#if DEBUG || CMUX_BENCH_HOOKS
/// A slow create reply for the first-keys proof (first-keys-proof.md item 2), DEBUG and bench builds only.
/// `CMUX_NEXT_DEBUG_SLOW_CREATE_MS=<ms>` makes the reply of every pane or terminal create (`new-tab`, `split`,
/// `new-pane-right`, `new-row`) reach the app `ms` later than the daemon sent it: the daemon has made the terminal and
/// sent its events, and keys typed meanwhile must still reach its PTY, in order, with none lost. Unset does nothing.
/// The composition root reads the variable and sets the local daemon's ``DaemonService/slowCreateReply``.
public nonisolated struct DebugSlowCreateReply: Sendable {
    /// The variable that sets the delay, in milliseconds.
    public static let environmentKey = "CMUX_NEXT_DEBUG_SLOW_CREATE_MS"
    static let labels: Set<String> = ["new-tab", "split", "new-pane-right", "new-row"]

    let delay: Duration

    /// - Parameter spec: The variable's value; nil, unparsable or negative is no delay.
    public init(_ spec: String?) {
        delay = .milliseconds(max(0, spec.flatMap { Int($0) } ?? 0))
    }

    /// Waits before the reply of `label` is handled.
    func beforeReply(_ label: String) async {
        guard delay > .zero, Self.labels.contains(label) else { return }
        // wakeup-allow: debug seam (CMUX_NEXT_DEBUG_SLOW_CREATE_MS), one wait per create reply of a slow-daemon run
        // timer-class-allow: a DEBUG/bench-only fault injection (unset by default): the reply itself waits, nothing is scheduled
        try? await Task.sleep(for: delay, tolerance: WakeLeeway.window(delay: delay).tolerance)
    }
}
#endif
