enum UsageTipID: String, CaseIterable, Sendable {
    case globalSearch = "global-search"
    case canvasLayout = "canvas-layout"
    case reopenBrowser = "reopen-browser"
    case workspaceGroups = "workspace-groups"
    case diffViewer = "diff-viewer"
    case splitZoom = "split-zoom"
    case keyboardSplitFocus = "keyboard-split-focus"
    case layoutTemplate = "layout-template"
    case previousSession = "previous-session"
    case vault = "vault"
    case browserFocus = "browser-focus"
    case terminalCopyMode = "terminal-copy-mode"
}
