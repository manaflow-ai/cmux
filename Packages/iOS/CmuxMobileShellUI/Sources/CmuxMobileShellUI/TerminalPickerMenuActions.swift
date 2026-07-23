import CmuxMobileShellModel

/// User actions emitted by ``TerminalPickerMenu`` without exposing mutable stores to its row subtree.
struct TerminalPickerMenuActions {
    let preparePresentation: () -> Void
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let createTerminal: () -> Void
    let openBrowser: () -> Void
    let selectBrowserStream: (String) -> Void
    let openChat: (String) -> Void
    let openLocalBrowser: () -> Void
    let retryBrowserStreamRefresh: () -> Void
}
