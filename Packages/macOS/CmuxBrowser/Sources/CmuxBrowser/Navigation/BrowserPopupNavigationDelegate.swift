public import Foundation
public import WebKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// `WKNavigationDelegate` for a browser popup window (`window.open`).
///
/// The delegate is a thin executor: it extracts the primitives WebKit hands it,
/// classifies the navigation through the stateless package decision enums
/// (``PopupNavigationActionDecision`` / ``PopupNavigationResponseDecision``), and
/// forwards the resolved effect to its ``BrowserPopupNavigationHosting`` host.
/// Every app-coupled effect (external routing, the insecure-HTTP alert, the
/// download determination, fallback reloads, popup teardown) lives on the host,
/// so the delegate holds no app state of its own.
///
/// `@MainActor` because `WKNavigationDelegate` is `@MainActor` and the host is a
/// main-actor `BrowserPopupWindowController`; co-locating removes any bridging.
@MainActor
public final class BrowserPopupNavigationDelegate: NSObject, WKNavigationDelegate {
    /// The app-side controller that owns the popup and performs the resolved
    /// navigation effects. Weak: the host retains the delegate (through the web
    /// view), not the other way around.
    public weak var host: (any BrowserPopupNavigationHosting)?

    /// The download delegate handed to any `WKDownload` this navigation spawns.
    public var downloadDelegate: (any WKDownloadDelegate)?

    public override init() {
        super.init()
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Branch classification lives in the package; the delegate executes the
        // resolved case (external routing, insecure-HTTP prompt, allow/download).
        switch PopupNavigationActionDecision.resolve(
            url: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame != false,
            shouldPerformDownload: navigationAction.shouldPerformDownload
        ) {
        case .allow:
            decisionHandler(.allow)

        case .routeExternally(let url):
            // External URL schemes → hand off to macOS
            host?.routeExternalPopupNavigation(url, source: "popupNavDelegate", in: webView)
            decisionHandler(.cancel)

        case .promptInsecureHTTP(let url):
            // Insecure HTTP → show same prompt as main browser
            #if DEBUG
            CMUXDebugLog.logDebugEvent("popup.nav.insecureHTTP url=\(url.absoluteString)")
            #endif
            host?.presentInsecureHTTPAlert(for: url, in: webView, decisionHandler: decisionHandler)

        case .download:
            decisionHandler(.download)
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Branch classification lives in the package; the delegate executes the
        // resolved case. The download determination stays app-side (it consults
        // the app's download-filename resolver) and is evaluated lazily so it runs
        // only after the main-frame and scheme guards pass, matching the original.
        switch PopupNavigationResponseDecision.resolve(
            isForMainFrame: navigationResponse.isForMainFrame,
            scheme: navigationResponse.response.url?.scheme,
            isDownload: { [weak host] in
                host?.popupNavigationResponseIsDownload(navigationResponse) ?? false
            }
        ) {
        case .allow:
            decisionHandler(.allow)

        case .download:
            decisionHandler(.download)
        }
    }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Parity with main browser: performDefaultHandling enables system keychain
        // lookups, MDM client certs, and SSO extensions (e.g. Microsoft Entra ID).
        completionHandler(.performDefaultHandling, nil)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        host?.handleWebContentProcessTermination(for: webView)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        #if DEBUG
        CMUXDebugLog.logDebugEvent("popup.download.didBecome source=navigationAction")
        #endif
        download.delegate = downloadDelegate
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        #if DEBUG
        CMUXDebugLog.logDebugEvent("popup.download.didBecome source=navigationResponse")
        #endif
        download.delegate = downloadDelegate
    }
}
