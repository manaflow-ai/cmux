extension BrowserTab {
    /// Scrolls the page by keyboard (``BrowserPageScroll``) in either engine, as cmux's own work:
    /// no user gesture. A closed or sleeping tab scrolls nothing.
    public func scroll(_ scroll: BrowserPageScroll) {
        // task-owner: fire-and-forget page scroll; nothing waits on it.
        Task { _ = try? await evaluate(scroll.script, world: .isolated, gesture: .cmux) }
    }
}
