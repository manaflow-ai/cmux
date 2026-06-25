import CmuxBrowser
import CmuxCore
import Foundation
import WebKit

/// Bridges ``BrowserFaviconService`` to a `BrowserPanel`'s live `WKWebView` and
/// remote-proxy environment.
///
/// `BrowserPanel` owns its `BrowserFaviconService`, which owns this adapter, which
/// holds a `weak` reference back to the panel. The weak back-reference breaks what
/// would otherwise be a retain cycle (panel → service → evaluator → panel) and lets
/// each refresh read the panel's current `webView`, identity, and proxy state,
/// which are reassigned on profile switches. WebKit's `evaluateJavaScript` is
/// main-thread only, so this is `@MainActor`.
@MainActor
final class BrowserFaviconWebViewEvaluator: BrowserFaviconScriptEvaluating {
    private weak var panel: BrowserPanel?

    /// Creates an evaluator bound to a panel.
    /// - Parameter panel: The panel whose live `webView` and proxy state the
    ///   favicon refresh runs against.
    init(panel: BrowserPanel) {
        self.panel = panel
    }

    func isCurrentWebView(instanceID: UUID) -> Bool {
        guard let panel else { return false }
        return panel.webViewInstanceID == instanceID
    }

    func evaluateJavaScriptString(_ script: String, timeoutNanoseconds: UInt64) async -> String? {
        guard let panel else { return nil }
        let webView = panel.webView
        return await withCheckedContinuation { continuation in
            var hasResumed = false

            func resume(_ value: String?) {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: value)
            }

            webView.evaluateJavaScript(script) { result, _ in
                let value = result as? String
                Task { @MainActor in
                    resume(value)
                }
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                resume(nil)
            }
        }
    }

    func remoteProxyPreparedRequest(from request: URLRequest) -> URLRequest {
        guard let panel else { return request }
        return panel.remoteProxyPreparedRequest(from: request, logScope: "faviconRewrite")
    }

    var remoteProxyEndpoint: BrowserProxyEndpoint? {
        panel?.activeRemoteProxyEndpoint
    }
}
