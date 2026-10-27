public import WebKit

extension BrowserAutomationNavigationCoordinator {
    /// Stops `ticket`'s navigation while it still waits to commit: its
    /// wait ends with `cancelled` and `webView`'s load is stopped, so no
    /// response of it commits. A REPL session that leaves a tab (the user
    /// moved it to another workspace) stops its navigations there this way.
    /// - Returns: Whether the navigation was still waiting; a committed or
    ///   ended one is left alone.
    @discardableResult
    public func stop(_ ticket: BrowserAutomationNavigationTicket, loading webView: WKWebView) -> Bool {
        guard cancel(ticket) else { return false }
        webView.stopLoading()
        return true
    }
}
