import AppKit
import CmuxNextAgentPane
import CmuxNextPages

/// An internal page in Chromium (Settings, Markdown, a file viewer) waits drawn when its pane shows another tab, as a
/// chat does (``AgentPageDrawnParking``): hidden in its pane, its Chromium page was told it is hidden, dropped its frame
/// and drew again on the switch back. HYPOTHESIS from code reading (not measured here): the 0.5 to 1.25 s blank
/// the chat's comments measure applies to these pages too (Leo, 2026-11-22, ask-5c771af51e: "constant rerenders on
/// every fucking page still").
extension InternalPageView: DrawnParkable {
    /// The page this view hosts, when it is a web page.
    private var webPage: PageWebView? { PageWebView.shown(in: content) }

    var keepsDrawnNow: Bool { webPage.map { $0.showsChromium && $0.hasPainted } ?? false }

    func parkedAway() {
        webPage?.setDrawnAway(true)
        if let page = webPage { PageWebView.syncChromiumVisibility(in: page) }
        webPage?.chromiumWindowMoved()
    }

    func parkedBack() { webPage?.setDrawnAway(false) }

    func placeAfterDrawnPark() {}

    /// The view is in its pane at its frame: the page's child window follows it.
    func shownAfterDrawnPark() {
        layoutSubtreeIfNeeded()
        webPage?.chromiumWindowMoved()
    }

    func drawnPicture() async -> NSImage? {
        guard let page = webPage else { return nil }
        return await page.snapshot()
    }

    func standOverDrawnPicture() {}
    func drawnPictureWent() {}

    func afterDrawnFrame(_ run: @escaping @MainActor () -> Void) {
        guard let page = webPage else { return run() }
        page.afterNextFrame { run() }
    }
}
