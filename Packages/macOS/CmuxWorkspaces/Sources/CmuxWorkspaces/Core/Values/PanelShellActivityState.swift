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
}
