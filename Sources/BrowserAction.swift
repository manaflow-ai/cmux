import CmuxPanes

/// A browser command executed against an explicitly captured panel target.
enum BrowserAction {
    case focus
    case back
    case forward
    case reload
    case openInDefaultBrowser
    case focusAddressBar
    case toggleFocusMode(reason: String)
    case toggleOmnibar
    case toggleDeveloperTools
    case showJavaScriptConsole
    case toggleReactGrab
    case toggleDesignMode(reason: String)
    case zoomIn
    case zoomOut
    case resetZoom
    case split(SplitDirection)
    case duplicateRight
    case moveToNewWorkspace
    case startFind
    case findNext
    case findPrevious
    case hideFind
}
