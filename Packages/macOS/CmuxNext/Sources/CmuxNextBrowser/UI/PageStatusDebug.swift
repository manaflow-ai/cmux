#if DEBUG
import AppKit

/// `debug.browser.page_status`: what a pane shows over its page. `error` is
/// the cmux error page's title and message ("" while hidden), `certificate`
/// "1" when it is the certificate warning, `gone` "1" while the sad tab shows,
/// `enginePage` "1" while the engine's own page shows for the failed load
/// (Chromium's certificate interstitial), and `holes` the Chromium page
/// window's holes, where the pane's own views show (`[[x, y, w, h], ...]`),
/// and `events` its last navigation events (`CEFEventTrace`).
/// `unresponsive` is "1" while the "Page unresponsive" card shows.
/// `press` presses a button first, through its own path as a click does:
/// `proceed` (the warning's Proceed), `wait` or `exit` (the card's Wait and
/// Exit page); `pressed` says whether there was one to press.
@MainActor
public struct PageStatusDebug {
    public let fields: [String: String]

    public init(_ chrome: BrowserChromeView, press: String? = nil) {
        let status = chrome.pageStatus
        let warning = !status.errorView.isHidden && status.errorView.isCertificateInterstitial
        let unresponsive = !status.unresponsiveView.isHidden
        let pressed: Bool
        switch press {
        case "proceed" where warning: status.errorView.onProceed?(); pressed = true
        case "wait" where unresponsive: status.unresponsiveView.onWait?(); pressed = true
        case "exit" where unresponsive: status.unresponsiveView.onExit?(); pressed = true
        default: pressed = false
        }
        fields = [
            "pressed": pressed ? "1" : "0",
            "unresponsive": status.unresponsiveView.isHidden ? "0" : "1",
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
