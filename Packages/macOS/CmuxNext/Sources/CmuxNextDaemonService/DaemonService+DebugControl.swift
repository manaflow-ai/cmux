public import CmuxNextControl
import CmuxNextDaemon

#if DEBUG || CMUX_BENCH_HOOKS
extension DaemonService {
    /// `debug.daemon` (DEBUG builds; a release router drops every `debug.*`
    /// method): the local daemon's connection and recovery as the app shows them,
    /// for the restore journey's daemon variants (scripts/cmux-next/restore-journey.py:
    /// a killed or stopped cmux-tui). `{action: "restart"}` runs Restart cmux-tui
    /// as the recovery button does after its confirm; `{action: "retry"}` is
    /// Retry Now. Both answer at once; the report shows how they go.
    ///
    /// The report: `startup` (`connecting`, `connected`, `unavailable` with
    /// `startup_error`), `connection` (`connected`, `connecting`,
    /// `disconnected`, `failed` with `connection_reason`), the daemon's `pid`
    /// while connected, `answering` (false while the connected daemon leaves its heartbeat
    /// unanswered and its connection stays open), `recovery`, and `windows`: each window's id and what it
    /// shows, from `windows` (`content`, `connecting` or `none`).
    @MainActor
    public func debugControlMethod(windows: @escaping @MainActor @Sendable () -> [(id: String, shows: String)]) -> ControlMethod {
        .mainActor("debug.daemon") { [weak self] call in
            guard let self else { return .value(.null) }
            // An empty dictionary of the control socket's own JSON type (CmuxNextDaemon has a JSONValue too).
            var report = call.params.filter { _ in false }
            var recovery = report
            switch call.params["action"]?.stringValue {
            case nil:
                break
            case "restart":
                // task-owner: the button's own call; the report shows its progress.
                Task { await self.recovery.restart() }
            case "retry":
                self.recovery.retryNow()
            case let other?:
                throw ControlError.invalidParams("debug.daemon: unknown action \(other) (restart, retry)")
            }
            report["action"] = call.params["action"]
            report["machine"] = .string(machineID)
            switch startup {
            case .connecting: report["startup"] = .string("connecting")
            case .connected: report["startup"] = .string("connected")
            case .unavailable(let error):
                report["startup"] = .string("unavailable")
                report["startup_error"] = .string(String(describing: error))
            }
            switch store.connectionState {
            case .connecting: report["connection"] = .string("connecting")
            case .connected: report["connection"] = .string("connected")
            case .disconnected(let why):
                report["connection"] = .string("disconnected")
                report["connection_reason"] = .string(why)
            case .failed(let why):
                report["connection"] = .string("failed")
                report["connection_reason"] = .string(why)
            }
            if let pid = store.identity?.pid { report["pid"] = .number(Double(pid)) }
            report["answering"] = .bool(!self.recovery.daemonNotAnswering)
            recovery["can_retry"] = .bool(self.recovery.canRetry)
            recovery["offers_restart"] = .bool(self.recovery.offersRestart)
            recovery["is_restarting"] = .bool(self.recovery.isRestarting)
            if let failure = self.recovery.restartFailure { recovery["restart_failure"] = .string(failure) }
            report["recovery"] = .object(recovery)
            report["windows"] = .array(windows().map { .object(["id": .string($0.id), "shows": .string($0.shows)]) })
            return .value(.object(report))
        }
    }
}
#endif
