#if DEBUG
import AppKit
import WebKit

/// `debug.browser.page_status`: what a pane shows over its page. `error` is
/// the cmux error page's title and message ("" while hidden), `certificate`
/// "1" when it is the certificate warning, `gone` "1" while the sad tab shows,
/// `enginePage` "1" while the engine's own page shows for the failed load
/// (Chromium's net error page or certificate interstitial), `title` the
/// tab's title, and `holes` the Chromium page
/// window's holes, where the pane's own views show (`[[x, y, w, h], ...]`),
/// and `events` its last navigation events (`CEFEventTrace`).
/// `unresponsive` is "1" while the "Page unresponsive" card shows.
/// `press` presses a button first, through its own path as a click does:
/// `proceed` (the warning's Proceed), `reload` (the sad tab's Reload), `wait`
/// or `exit` (the card's Wait and Exit page); `pressed` says whether there was
/// one to press. `gone_text` is the sad tab's title, message and button;
/// `page_pid` a WebKit tab's WebContent process (crash e2e, cx-d0d.2).
/// `can_go_back` and `can_go_forward` are "1" while the toolbar offers Back
/// and Forward (restore journey).
@MainActor
public struct PageStatusDebug {
    public let fields: [String: String]

    public init(_ chrome: BrowserChromeView, press: String? = nil) {
        let status = chrome.pageStatus
        // Only the views made so far: a view never shown is hidden (and stays unmade).
        let error = status.errorViewIfMade.flatMap { $0.isHidden ? nil : $0 }
        let goneView = status.goneViewIfMade.flatMap { $0.isHidden ? nil : $0 }
        let card = status.unresponsiveViewIfMade.flatMap { $0.isHidden ? nil : $0 }
        let warning = error?.isCertificateInterstitial == true
        let gone = goneView != nil
        let goneText = goneView?.debugText ?? ""
        let unresponsive = card != nil
        let pressed: Bool
        switch press {
        case "proceed" where warning: error?.onProceed?(); pressed = true
        case "reload" where gone: goneView?.pressReload(); pressed = true
        case "wait" where unresponsive: card?.onWait?(); pressed = true
        case "exit" where unresponsive: card?.onExit?(); pressed = true
        default: pressed = false
        }
        fields = [
            "pressed": pressed ? "1" : "0",
            "can_go_back": chrome.tab.state.canGoBack ? "1" : "0",
            "can_go_forward": chrome.tab.state.canGoForward ? "1" : "0",
            "unresponsive": unresponsive ? "1" : "0",
            "gone_text": goneText,
            "page_pid": (chrome.tab as? WebKitTab).flatMap { Self.webProcess($0.webView) }.map(String.init) ?? "",
            "error": error?.debugText ?? "",
            "certificate": warning ? "1" : "0",
            "gone": gone ? "1" : "0",
            "enginePage": chrome.tab.state.loadError?.engineShowsPage == true ? "1" : "0",
            "title": chrome.tab.state.title ?? "",
            "holes": "\(((chrome.tab as? CEFTab)?.pageWindowHoles ?? []).map { [$0.minX, $0.minY, $0.width, $0.height] })",
            "events": CEFEventTrace.recent((chrome.tab as? CEFTab)?.browserID).joined(separator: " | "),
        ]
    }

    private static func webProcess(_ webView: WKWebView) -> Int32? {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_webProcessIdentifier")
        // crash-allow: KVC read of the WebKit private key above, only after responds(to:) confirmed it.
        guard webView.responds(to: selector), let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }
}
#endif
