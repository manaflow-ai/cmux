import Foundation
import WebKit

extension BrowserPanel {
    func automationReloadTargetURL() -> URL? {
        restorableDisplayURLForCurrentErrorPage(liveURL: webView.url)
            ?? Self.remoteProxyDisplayURL(for: navigationDelegate?.lastAttemptedURL)
            ?? navigationDelegate?.lastAttemptedURL
            ?? resolvedCurrentSessionHistoryURL()
            ?? currentURL
            ?? URL(string: "about:blank")
    }

    /// Uses the failed request, even before WebKit commits the generated error page.
    /// Returns true for an interstitial whose retry was handled or explicitly disabled.
    func retryFailedNavigationForReload(
        mode: BrowserPanelReloadMode,
        onNavigationStarted: ((WKNavigation?) -> Void)? = nil
    ) -> Bool {
        guard let retry = navigationDelegate?.activeErrorPageRetry() else { return false }
        var request: URLRequest
        switch retry {
        case .request(let failedRequest):
            request = failedRequest
        case .urlOnly:
            guard let url = navigationDelegate?.activeErrorPageDisplayURL else {
                onNavigationStarted?(nil)
                return true
            }
            request = URLRequest(url: url)
        case .disabled:
            // A streamed/oversized upload or a blocked page must not become a GET.
            onNavigationStarted?(nil)
            return true
        }
        if mode == .hard {
            request.cachePolicy = mode.recoveryCachePolicy
        }
        navigateWithoutInsecureHTTPPrompt(
            request: request,
            recordTypedNavigation: false,
            preserveRestoredSessionHistory: true,
            onNavigationStarted: onNavigationStarted
        )
        return true
    }
}
