/// The shell-activity classification of a terminal panel, as reported by
/// shell integration (prompt markers) over the control socket.
///
/// Raw values are a wire format (control-socket `state` strings and session
/// snapshots); they are frozen. Formerly `Workspace.PanelShellActivityState`.
public enum PanelShellActivityState: String, Sendable, Equatable {
    /// No shell-integration report has been received for the panel.
    case unknown
    /// The shell is sitting at an idle prompt.
    case promptIdle
    /// A foreground command is currently running.
    case commandRunning

    /// Parses a reported shell-activity token (the control socket's
    /// `state`/`shell_state`/`activity` argument) into a classification.
    ///
    /// The token is trimmed and lowercased, then matched against the accepted
    /// aliases (`prompt`/`idle` → ``promptIdle``; `running`/`busy`/`command` →
    /// ``commandRunning``; `unknown`/`clear` → ``unknown``). An unrecognized
    /// token yields `nil` so the control path can reject it as
    /// `invalid_params`. Alias set is frozen wire behavior.
    public static func parseReported(_ rawState: String) -> PanelShellActivityState? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "prompt", "idle":
            return .promptIdle
        case "running", "busy", "command":
            return .commandRunning
        case "unknown", "clear":
            return .unknown
        default:
            return nil
        }
    }

    /// Whether closing a panel in this shell-activity state should prompt for
    /// confirmation.
    ///
    /// An idle prompt (``promptIdle``) never needs confirmation; a running
    /// foreground command (``commandRunning``) always does. When the state is
    /// ``unknown`` (no shell-integration report received), the decision defers
    /// to `fallbackNeedsConfirmClose`, the panel's own heuristic.
    public func closeConfirmationRequired(fallbackNeedsConfirmClose: Bool) -> Bool {
        switch self {
        case .promptIdle:
            return false
        case .commandRunning:
            return true
        case .unknown:
            return fallbackNeedsConfirmClose
        }
    }
}
