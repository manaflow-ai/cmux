import AppKit
import WebKit

struct BrowserNavigationModifierBypassPolicy {
    private let modifierPolicy: OpenRoutingModifierPolicy

    init(modifierPolicy: OpenRoutingModifierPolicy = OpenRoutingModifierPolicy()) {
        self.modifierPolicy = modifierPolicy
    }

    func shouldOpenInDefaultBrowser(
        url: URL,
        navigationType: WKNavigationType,
        modifierFlags: NSEvent.ModifierFlags,
        buttonNumber: Int,
        hasRecentMiddleClickIntent: Bool = false
    ) -> Bool {
        guard Self.canOpenInDefaultBrowser(url) else {
            return false
        }
        guard modifierPolicy.shouldBypassCmuxOpenRouting(modifierFlags: modifierFlags) else {
            return false
        }
        return browserNavigationShouldOpenInNewTab(
            navigationType: navigationType,
            modifierFlags: modifierFlags,
            buttonNumber: buttonNumber,
            hasRecentMiddleClickIntent: hasRecentMiddleClickIntent
        )
    }

    @discardableResult
    func openDefaultBrowserIfNeeded(
        navigationAction: WKNavigationAction,
        webView: WKWebView,
        debugEventName: String
    ) -> Bool {
        let hasRecentMiddleClickIntent = CmuxWebView.hasRecentMiddleClickIntent(for: webView)
        guard let url = navigationAction.request.url,
              shouldOpenInDefaultBrowser(
                  url: url,
                  navigationType: navigationAction.navigationType,
                  modifierFlags: navigationAction.modifierFlags,
                  buttonNumber: navigationAction.buttonNumber,
                  hasRecentMiddleClickIntent: hasRecentMiddleClickIntent
              ) else {
            return false
        }
#if DEBUG
        cmuxDebugLog("\(debugEventName) kind=openDefaultBrowserModifierBypass url=\(browserNavigationDebugURL(url))")
#endif
        NSWorkspace.shared.open(url)
        return true
    }

    private static func canOpenInDefaultBrowser(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }
}
