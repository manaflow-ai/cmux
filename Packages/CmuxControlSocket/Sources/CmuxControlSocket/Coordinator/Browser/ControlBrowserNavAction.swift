/// The simple history navigation a `browser.back`/`forward`/`reload` command
/// performs on the target browser panel (the legacy `v2BrowserNavSimple`
/// action string).
public enum ControlBrowserNavAction: Sendable, Equatable {
    /// `browser.back` → `goBack()`.
    case back
    /// `browser.forward` → `goForward()`.
    case forward
    /// `browser.reload` → `reload()`.
    case reload
}
