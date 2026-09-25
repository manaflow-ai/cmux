import CmuxMobileShellModel

/// User actions emitted by ``TerminalPickerMenu`` without exposing mutable stores to its row subtree.
struct TerminalPickerMenuActions {
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let selectMacSurface: (MobileSurfacePreview.ID) -> Void
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    /// A grouped section's action (``TerminalPickerMenuValue/sshTabLayout``):
    /// "Split Pane" on a tmux window, "New Tab" on a cmux-tui screen.
    var createSSHTab: (String) -> Void = { _ in }
    let openBrowser: () -> Void
    let selectBrowserStream: (String) -> Void
    let selectSimulatorStream: (String) -> Void
    let openTextSheet: () -> Void
    let copyDebugLogs: () -> Void
    let sendFeedback: () -> Void
}
