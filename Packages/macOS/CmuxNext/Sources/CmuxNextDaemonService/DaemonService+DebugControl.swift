public import CmuxNextControl
import CmuxNextDaemon

#if DEBUG || CMUX_BENCH_HOOKS
extension DaemonService {
    /// `debug.daemon_requests` (DEBUG and bench builds): the app's own daemon requests, each from its
    /// send to its reply or failure (``DaemonRequestLatency``), since launch, on the local daemon's connection. Answered off the main
    /// actor (it reads atomics), so it answers while the main thread is busy. `bounds_us` are the
    /// buckets' upper bounds; `counts` has one more entry, the overflow bucket. A reader diffs two
    /// reads for a window (scripts/cmux-next/austins-day reads one before and one after its load).
    public nonisolated func debugRequestLatencyMethod() -> ControlMethod {
        .snapshot("debug.daemon_requests") { [requestLatency] call in
            // Before the local connection starts (or with a remote daemon): no requests yet.
            let snapshot = requestLatency.probe?.snapshot() ?? DaemonRequestLatency().snapshot()
            // The control socket's own JSON type, made without naming it (CmuxNextDaemon has a JSONValue too).
            var report = call.params.filter { _ in false }
            report["bounds_us"] = .array(snapshot.boundsMicroseconds.map { .number(Double($0)) })
            report["counts"] = .array(snapshot.counts.map { .number(Double($0)) })
            report["count"] = .number(Double(snapshot.count))
            report["errors"] = .number(Double(snapshot.errors))
            report["timeouts"] = .number(Double(snapshot.timeouts))
            report["max_us"] = .number(Double(snapshot.maxMicroseconds))
            for (key, percent) in [("p50_us", UInt64(50)), ("p95_us", 95), ("p99_us", 99)] {
                if let micros = snapshot.percentileMicroseconds(percent) {
                    report[key] = .number(Double(micros))
                } else {
                    report[key] = .null
                }
            }
            return .object(report)
        }
    }

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
    /// unanswered and its connection stays open), `recovery` (`start_failure`: `disk_full` or `failed` while the last
    /// start failed, with `start_failure_detail`), and `windows`: each window's id and what it
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
            // Why the last start failed (restore fuzz h2): `disk_full` or `failed`, and the launcher's text.
            if let start = self.recovery.startFailure {
                recovery["start_failure"] = .string(start.kind.rawValue)
                recovery["start_failure_detail"] = .string(start.detail)
            }
            report["recovery"] = .object(recovery)
            report["windows"] = .array(windows().map { .object(["id": .string($0.id), "shows": .string($0.shows)]) })
            return .value(.object(report))
        }
    }
}
#endif
