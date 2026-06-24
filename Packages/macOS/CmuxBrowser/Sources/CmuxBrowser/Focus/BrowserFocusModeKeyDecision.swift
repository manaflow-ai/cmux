/// The routing verdict the browser focus-mode plain-Escape machine returns for a
/// single key event reaching a focused `WKWebView`.
///
/// Browser focus mode hands the focused web view first ownership of page and app
/// shortcuts. A plain Escape is special: the first one is forwarded to the page
/// (which arms an exit), and a second plain Escape within the sequence window
/// exits focus mode. Every other key event in focus mode is either forwarded to
/// the web view (mode active) or treated as inactive (mode not active). This
/// enum names exactly those three outcomes so the owning panel can apply them
/// without re-deriving the policy.
public enum BrowserFocusModeKeyDecision: Sendable, Equatable {
    /// Focus mode is not active (or the panel is ineligible); the event is not a
    /// focus-mode concern.
    case inactive

    /// Forward the event to the focused web view (the page sees it first).
    case forwardToWebView

    /// Swallow the event entirely (handled by focus mode itself).
    case consume
}
