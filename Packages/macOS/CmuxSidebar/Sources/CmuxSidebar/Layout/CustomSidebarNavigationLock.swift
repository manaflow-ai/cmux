public import Foundation
public import WebKit
internal import os

/// Holds an armed web sidebar's main frame on the source that armed it.
///
/// Without this, arming means nothing: a document could `location = 'https://…'`, or a loopback page
/// could redirect to a public host, and the resulting page would inherit a registered focus handler
/// it never qualified for. So every main-frame navigation outside the ``CustomSidebarFocusScope`` is
/// cancelled — including server redirects, which arrive as a fresh policy decision rather than as
/// part of the original one.
///
/// Only armed sources get a lock. An ordinary web sidebar has no bridge to protect and stays free to
/// navigate wherever its author wants.
@MainActor
public final class CustomSidebarNavigationLock: NSObject, WKNavigationDelegate {
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "CustomSidebarFocus")

    private let scope: CustomSidebarFocusScope

    /// Creates a lock for one armed source.
    ///
    /// - Parameter scope: The source the main frame is pinned to.
    public init(scope: CustomSidebarFocusScope) {
        self.scope = scope
        super.init()
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // A `nil` target frame is a new-window request, which for a chrome-less sidebar can only be
        // a page trying to leave; treat it as the main frame so it is judged, not waved through.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard scope.permitsNavigation(to: navigationAction.request.url, isMainFrame: isMainFrame) else {
            CustomSidebarNavigationLock.logger.error(
                "custom sidebar navigation cancelled: target is outside the armed source"
            )
            return .cancel
        }
        return .allow
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        guard scope.permitsNavigation(to: navigationResponse.response.url, isMainFrame: true) else {
            CustomSidebarNavigationLock.logger.error(
                "custom sidebar response cancelled: response is outside the armed source"
            )
            return .cancel
        }
        return .allow
    }
}
