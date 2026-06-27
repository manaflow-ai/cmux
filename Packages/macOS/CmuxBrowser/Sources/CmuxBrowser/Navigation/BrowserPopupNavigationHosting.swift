public import Foundation
public import WebKit

/// The app-side seam a ``BrowserPopupNavigationDelegate`` drives for the
/// navigation effects it cannot own from the package.
///
/// `BrowserPopupWindowController` conforms to this protocol. The delegate only
/// classifies each navigation through the stateless package decision enums
/// (``PopupNavigationActionDecision`` / ``PopupNavigationResponseDecision``) and
/// then forwards the resolved effect through the host:
///
/// - ``requestNavigation(_:in:)`` reloads a fallback request after an
///   insecure-HTTP allow.
/// - ``presentInsecureHTTPAlert(for:in:decisionHandler:)`` shows the app's
///   3-button insecure-HTTP alert (its `String(localized:)` strings stay
///   app-side so they bind to the app bundle's `.xcstrings`, preserving
///   translations).
/// - ``handleWebContentProcessTermination(for:)`` closes the popup when its web
///   content process dies.
/// - ``routeExternalPopupNavigation(_:source:in:)`` hands an external-scheme URL
///   to macOS via the app's `browserHandleExternalNavigation`, which cannot move
///   into the package (it reaches the app's external-navigation presenter).
/// - ``popupNavigationResponseIsDownload(_:)`` decides whether a response should
///   be downloaded via the app's `BrowserDownloadFilenameResolver`. It is
///   evaluated lazily (only after the main-frame and scheme guards pass),
///   preserving the delegate's original evaluation order.
///
/// `@MainActor` because every effect is one main-actor turn driven by a WebKit
/// navigation callback (the `WKNavigationDelegate` methods are themselves
/// `@MainActor`), and the host (`BrowserPopupWindowController`) lives on main,
/// so forwarding stays a plain call with no bridging.
///
/// Faithful-lift note: in the legacy in-delegate code the external-routing and
/// download-determination ran without consulting the controller, so they fired
/// even if the `weak controller` had been released. Routing them through the
/// host binds them to host liveness, but the host (the controller) owns the web
/// view whose delegate this is and is retained by the panel + associated object
/// for the whole navigation, so a nil host during a navigation callback is
/// unreachable in practice.
@MainActor
public protocol BrowserPopupNavigationHosting: AnyObject {
    /// Loads `request` in `webView` as the insecure-HTTP allow fallback (legacy
    /// `controller?.requestNavigation(_:in:)`).
    func requestNavigation(_ request: URLRequest, in webView: WKWebView)

    /// Presents the app's insecure-HTTP alert for `url`, resolving
    /// `decisionHandler` with the user's choice (legacy
    /// `controller?.presentInsecureHTTPAlert(for:in:decisionHandler:)`).
    func presentInsecureHTTPAlert(
        for url: URL,
        in webView: WKWebView,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    )

    /// Closes the popup whose web content process terminated (legacy
    /// `controller?.handleWebContentProcessTermination(for:)`).
    func handleWebContentProcessTermination(for webView: WKWebView)

    /// Hands `url` off for external routing, after which the delegate cancels the
    /// in-page navigation. Wraps the app's `browserHandleExternalNavigation` with
    /// the legacy source tag `"popupNavDelegate"`.
    func routeExternalPopupNavigation(_ url: URL, source: String, in webView: WKWebView)

    /// Whether `navigationResponse` should be treated as a download, per the
    /// app's download-filename resolver. Evaluated lazily by
    /// ``PopupNavigationResponseDecision/resolve(isForMainFrame:scheme:isDownload:)``.
    func popupNavigationResponseIsDownload(_ navigationResponse: WKNavigationResponse) -> Bool
}
