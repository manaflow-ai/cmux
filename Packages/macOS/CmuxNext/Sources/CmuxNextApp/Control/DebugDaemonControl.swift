import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings

#if DEBUG
/// CmuxNextDaemon has a `JSONValue` too; the control socket speaks the settings one.
private typealias JSONValue = CmuxNextSettings.JSONValue

/// `debug.daemon` (DEBUG builds; a release router drops every `debug.*`
/// method): the local daemon's connection and recovery as the app shows them,
/// for the restore journey's daemon variants (scripts/cmux-next/restore-journey.py:
/// a killed or stopped cmux-tui). `{action: "restart"}` runs Restart cmux-tui
/// as the recovery button does after its confirm; `{action: "retry"}` is
/// Retry Now. Both answer at once; the report shows how they go.
@MainActor
enum DebugDaemonControl {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        [
            .mainActor("debug.daemon") { [weak services] call in
                guard let services else { return .value(.null) }
                let recovery = services.daemon.recovery
                var answer = Self.report(services)
                switch call.params["action"]?.stringValue {
                case nil:
                    return .value(answer)
                case "restart":
                    // task-owner: the button's own call; the report shows its progress.
                    Task { await recovery.restart() }
                case "retry":
                    recovery.retryNow()
                case let other?:
                    throw ControlError.invalidParams("debug.daemon: unknown action \(other) (restart, retry)")
                }
                if case .object(var fields) = answer {
                    fields["action"] = call.params["action"] ?? .null
                    answer = .object(fields)
                }
                return .value(answer)
            },
        ]
    }

    /// The local daemon's startup (`connecting`, `connected`, `unavailable`
    /// with its error), its connection (`connected`, `connecting`,
    /// `disconnected`, `failed` with the reason), the daemon's pid while
    /// connected, the recovery's state, and per window what it shows:
    /// `content` (a workspace), `connecting` (DaemonConnectingView) or `none`.
    static func report(_ services: AppServices) -> CmuxNextSettings.JSONValue {
        let daemon = services.daemon
        let (startup, startupError): (String, String?) = switch daemon.startup {
        case .connecting: ("connecting", nil)
        case .connected: ("connected", nil)
        case .unavailable(let error): ("unavailable", String(describing: error))
        }
        let (connection, reason): (String, String?) = switch daemon.store.connectionState {
        case .connecting: ("connecting", nil)
        case .connected: ("connected", nil)
        case .disconnected(let why): ("disconnected", why)
        case .failed(let why): ("failed", why)
        }
        let recovery = daemon.recovery
        var windows: [JSONValue] = []
        for controller in services.windows.controllers {
            let shows = controller.content != nil ? "content" : controller.connectingView != nil ? "connecting" : "none"
            windows.append(.object(["id": .string(controller.state.id), "shows": .string(shows)]))
        }
        var recoveryFields: [String: JSONValue] = [:]
        recoveryFields["can_retry"] = .bool(recovery.canRetry)
        recoveryFields["offers_restart"] = .bool(recovery.offersRestart)
        recoveryFields["is_restarting"] = .bool(recovery.isRestarting)
        recoveryFields["restart_failure"] = recovery.restartFailure.map { JSONValue.string($0) } ?? .null
        var fields: [String: JSONValue] = [:]
        fields["machine"] = .string(daemon.machineID)
        fields["startup"] = .string(startup)
        fields["startup_error"] = startupError.map { JSONValue.string($0) } ?? .null
        fields["connection"] = .string(connection)
        fields["connection_reason"] = reason.map { JSONValue.string($0) } ?? .null
        fields["pid"] = daemon.store.identity.map { JSONValue.number(Double($0.pid)) } ?? .null
        fields["recovery"] = .object(recoveryFields)
        fields["windows"] = .array(windows)
        return .object(fields)
    }
}
#endif
