#if DEBUG
import AppKit

/// `debug.browser.page_status`: what a pane shows over its page. `error` is
/// the cmux error page's title and message ("" while hidden), `certificate`
/// "1" when it is the certificate warning, `gone` "1" while the sad tab shows,
/// `enginePage` "1" while the engine's own page shows for the failed load
/// (Chromium's certificate interstitial), and `holes` the Chromium page
/// window's holes, where the pane's own views show (`[[x, y, w, h], ...]`),
/// and `events` its last navigation events (`CEFEventTrace`).
/// `pressProceed` presses the warning's Proceed button first (its own path,
/// as a click does), and `pressed` says whether there was one to press.
@MainActor
public struct PageStatusDebug {
    public let fields: [String: String]

    public init(_ chrome: BrowserChromeView, pressProceed: Bool = false) {
        let status = chrome.pageStatus
        let warning = !status.errorView.isHidden && status.errorView.isCertificateInterstitial
        if pressProceed, warning { status.errorView.onProceed?() }
        fields = [
            "pressed": pressProceed && warning ? "1" : "0",
            "error": status.errorView.isHidden ? "" : status.errorView.debugText,
            "certificate": !status.errorView.isHidden && status.errorView.isCertificateInterstitial ? "1" : "0",
            "gone": status.goneView.isHidden ? "0" : "1",
            "enginePage": chrome.tab.state.loadError?.engineShowsPage == true ? "1" : "0",
            "holes": "\(((chrome.tab as? CEFTab)?.pageWindowHoles ?? []).map { [$0.minX, $0.minY, $0.width, $0.height] })",
            "events": CEFEventTrace.recent((chrome.tab as? CEFTab)?.browserID).joined(separator: " | "),
        ]
    }
}
#endif
