import CmuxMobileShellModel

/// User actions emitted by ``SurfaceDeckBar`` without exposing mutable stores to its chip subtree.
struct SurfaceDeckActions {
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let presentPaneMap: () -> Void
    let createTerminal: () -> Void
    let openBrowser: () -> Void
    let createWorkspace: () -> Void
}
