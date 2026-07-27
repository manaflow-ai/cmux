import CmuxMobileShellModel

/// User actions emitted by ``TerminalPickerMenu`` without exposing mutable stores to its row subtree.
struct TerminalPickerMenuActions {
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    let openBrowser: () -> Void
    let openTextSheet: () -> Void
    let copyDebugLogs: () -> Void
    let sendFeedback: () -> Void
}
