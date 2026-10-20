extension BrowserTab {
    /// Scrolls a page restored from its engine's own history to `y`, the position saved at quit,
    /// once it loads (``BrowserRestoredSession``); engines whose saved state keeps an older
    /// position need it.
    ///
    /// - Parameter y: The vertical scroll offset measured when the page was saved.
    public func scrollOnLoad(to y: Double) {
        if let tab = self as? WebKitTab {
            tab.restored.scrollOnLoad(to: y)
        } else if let tab = self as? CEFTab {
            tab.restored.scrollOnLoad(to: y)
        }
    }
}
