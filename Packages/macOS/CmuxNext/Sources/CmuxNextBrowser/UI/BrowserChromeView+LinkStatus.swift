import AppKit
import CmuxNextDesign

// The hovered link's address (`BrowserTab.linkStatus`) in a bubble at the
// bottom left of this chrome's page area (`LinkStatusBubbleView`), on the
// window's overlay host so it shows above a Chromium page and only inside it.
extension BrowserChromeView {
    /// The bubble shown now, if any (tests, diagnostics).
    var linkStatusBubble: LinkStatusBubbleView? {
        pageOverlays.views.lazy.compactMap { $0 as? LinkStatusBubbleView }.first
    }

    /// The hovered link the bubble shows (tests, diagnostics); nil when none.
    public var linkStatusText: String? { linkStatusBubble?.text }

    /// Where the bubble draws (diagnostics): `overlay_host` (above the page),
    /// `window` (under a Chromium page), `offscreen` (parked), nil: none.
    public var linkStatusPlacement: String? {
        linkStatusBubble.map { $0.window is OverlayHostPanel ? "overlay_host" : $0.window == nil ? "offscreen" : "window" }
    }

    /// Shows the tab's hovered link, or takes the bubble away when the
    /// pointer left it. Runs under the chrome's observation of the tab.
    func renderLinkStatus() {
        guard let text = tab.linkStatus, !text.isEmpty else {
            if let bubble = linkStatusBubble { pageOverlays.remove(bubble) }
            return
        }
        let bubble = linkStatusBubble ?? {
            let made = LinkStatusBubbleView()
            pageOverlays.add(made, placement: .bottomLeading, passesThroughClicks: true)
            return made
        }()
        bubble.text = text
        fitLinkStatus()
        syncPageOverlays()
    }

    /// Keeps the bubble at most half the page wide (on layout).
    func fitLinkStatus() {
        linkStatusBubble?.fit(pageWidth: contentContainer.bounds.width)
    }
}
