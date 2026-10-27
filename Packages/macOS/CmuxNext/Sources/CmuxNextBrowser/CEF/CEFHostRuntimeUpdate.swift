import CmuxNextWakeups

/// A newer Chromium runtime the Chromium Host restarts on at an idle moment (task 087 of
/// plans/cmux-next/chrome-parity/p01-process.md, ``CEFRuntime/hostRuntimeChanged()``).
final class CEFHostRuntimeUpdate {
    enum Phase: Equatable {
        /// No newer runtime waits.
        case none
        /// A newer runtime waits for an idle moment; `blocker` says why the last check kept the host (nil: not checked).
        case waiting(blocker: String?)
        /// The host ends, and the next one starts on the newer runtime with every page.
        case restarting
    }

    /// How long a kept host waits before the next check.
    static let retryAfter: Duration = .seconds(60)

    var phase: Phase = .none
    /// The next check while ``Phase/waiting(blocker:)``, on the runtime's wait deadlines.
    var retry: AlignedWakeups.Ticket?
    /// A check runs (its page probes are out).
    var checking = false
    /// Hosts restarted on a newer runtime.
    var restarts = 0
    /// What the page itself says keeps it on its host (``CEFTab/hostRestartBlocker()``; a test's stand-in).
    var pageBlocker: @MainActor (CEFTab) async -> String? = { await $0.hostRestartBlocker() }

    /// `debug.updater` `chromium-runtime`.
    var report: String {
        switch phase {
        case .none: "none"
        case .waiting(let blocker): "waiting: \(blocker ?? "not checked")"
        case .restarting: "restarting"
        }
    }
}
