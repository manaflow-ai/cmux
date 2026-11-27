public import AppKit

/// A ``DrawnParkable`` whose page is one `PageWebView` (an internal page: Settings, Markdown, a file viewer): it names its
/// page and the rest follows. HYPOTHESIS from code reading, not measured here: such a page in Chromium drops its frame
/// when its pane hides it, as a chat did (`PageWebView+DrawnAway`: 0.5 to 1.25 s blank on the switch back; Leo,
/// 2026-11-22, ask-5c771af51e: "constant rerenders on every fucking page still").
@MainActor
public protocol DrawnWebParkable: DrawnParkable {
    var drawnWebPage: PageWebView? { get }
}

extension DrawnWebParkable {
    public var keepsDrawnNow: Bool { drawnWebPage.map { $0.showsChromium && $0.hasPainted } ?? false }

    public func parkedAway() {
        guard let page = drawnWebPage else { return }
        page.setDrawnAway(true)
        PageWebView.syncChromiumVisibility(in: page)
        page.chromiumWindowMoved()
    }

    public func parkedBack() { drawnWebPage?.setDrawnAway(false) }
    public func placeAfterDrawnPark() {}

    /// The view is in its pane at its frame: the page's child window follows it.
    public func shownAfterDrawnPark() {
        layoutSubtreeIfNeeded()
        drawnWebPage?.chromiumWindowMoved()
    }

    public func drawnPicture() async -> NSImage? { await drawnWebPage?.snapshot() }
    public func standOverDrawnPicture() {}
    public func drawnPictureWent() {}

    public func afterDrawnFrame(_ run: @escaping @MainActor () -> Void) {
        guard let page = drawnWebPage else { return run() }
        page.afterNextFrame { run() }
    }
}
