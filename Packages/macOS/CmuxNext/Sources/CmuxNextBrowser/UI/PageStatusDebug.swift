#if DEBUG
import AppKit
import WebKit

/// `debug.browser.page_status`: what a pane shows over its page. `error` is
/// the cmux error page's title and message ("" while hidden), `certificate`
/// "1" when it is the certificate warning, `gone` "1" while the sad tab shows,
/// `enginePage` "1" while the engine's own page shows for the failed load
/// (Chromium's certificate interstitial), and `holes` the Chromium page
/// window's holes, where the pane's own views show (`[[x, y, w, h], ...]`),
/// and `events` its last navigation events (`CEFEventTrace`).
/// `press` "proceed" presses the warning's Proceed button first (its own path,
/// as a click does), "reload" the sad tab's Reload button, and `pressed` says
/// whether there was one to press. `gone_text` is the sad tab's title, message
/// and button; `page_pid` a WebKit tab's WebContent process (crash e2e, cx-d0d.2).
@MainActor
public struct PageStatusDebug {
    public let fields: [String: String]

    public init(_ chrome: BrowserChromeView, press: String? = nil) {
        let status = chrome.pageStatus
        let warning = !status.errorView.isHidden && status.errorView.isCertificateInterstitial
        let gone = !status.goneView.isHidden
        let goneText = gone ? status.goneView.debugText : ""
        var pressed = false
        if press == "proceed", warning { status.errorView.onProceed?(); pressed = true }
        if press == "reload", gone { status.goneView.pressReload(); pressed = true }
        fields = [
            "pressed": pressed ? "1" : "0",
            "gone_text": goneText,
            "page_pid": (chrome.tab as? WebKitTab).flatMap { Self.webProcess($0.webView) }.map(String.init) ?? "",
            "error": status.errorView.isHidden ? "" : status.errorView.debugText,
            "certificate": !status.errorView.isHidden && status.errorView.isCertificateInterstitial ? "1" : "0",
            "gone": gone ? "1" : "0",
            "enginePage": chrome.tab.state.loadError?.engineShowsPage == true ? "1" : "0",
            "holes": "\(((chrome.tab as? CEFTab)?.pageWindowHoles ?? []).map { [$0.minX, $0.minY, $0.width, $0.height] })",
            "events": CEFEventTrace.recent((chrome.tab as? CEFTab)?.browserID).joined(separator: " | "),
        ]
    }

    private static func webProcess(_ webView: WKWebView) -> Int32? {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector), let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }
}
#endif
