@MainActor
extension PageWebView {
    /// Freezes a page the preload slot parks outside the page lifecycle (the New Tab agent pane,
    /// p13-webui-044): the lifecycle's own freeze (``freezePage()``, hidden first, as Chrome freezes
    /// only hidden pages). False when refused: the page still shows, or its engine page is starting.
    @discardableResult
    package func freezeParkedPreload() -> Bool { freezePage() }

    /// Thaws a page ``freezeParkedPreload()`` froze, before it shows (``thawPage()``).
    package func thawParkedPreload() { thawPage() }
}
