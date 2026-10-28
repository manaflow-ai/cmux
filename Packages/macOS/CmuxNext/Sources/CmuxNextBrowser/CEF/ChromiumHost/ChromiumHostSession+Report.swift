#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import Foundation

extension ChromiumHostSession {
    /// State for `debug.chromium_host`.
    public var report: [String: Any] {
        let phaseText: String
        switch phase {
        case .idle: phaseText = "idle"
        case .starting: phaseText = "starting"
        case .running: phaseText = "running"
        case .ended(let reason): phaseText = "ended: \(reason)"
        case .exitedIdle: phaseText = "exited idle"
        }
        let backlog = connection?.backlog
        var fields: [String: Any] = [
                "phase": phaseText, "pid": Int(pid), "fork_api": Int(forkAPI), "context_id": Int(contextID),
                "shown_context_id": Int(view.contextID), "url": url, "title": title, "restarts": restarts,
                "idle_exits": idleExits, "idle_exit_s": idleExit.map(Self.seconds) ?? 0,
                "live": isLive, "idle_exit_armed": isIdleExitArmed, "stand_in": view.standIn != nil,
                "exits": exits, "error": lastError ?? "", "log_file": configuration.logFile ?? "",
                "wire_waiting": backlog?.waiting ?? 0, "wire_coalesced": Int(clamping: backlog?.coalesced ?? 0),
                "input_presented_failed": failedInputPresentations, "password_input": view.passwordInput.isOn]
        for (name, count) in view.textInput.stats.report { fields[name] = count }
        return fields
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
#endif
