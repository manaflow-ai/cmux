/// Placement of browser tabs opened by terminal links or intercepted `open` commands.
public enum TerminalLinkBrowserPlacement: String, CaseIterable, Sendable, SettingCodable {
    /// Reuse a pane to the right, or create a right split when none exists.
    case split
    /// Create a browser tab in the pane containing the source terminal.
    case samePane
}
