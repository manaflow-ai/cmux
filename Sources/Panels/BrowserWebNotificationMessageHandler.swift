import Foundation
import WebKit

/// Receives and validates page-created notifications from one browser webview generation.
final class BrowserWebNotificationMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxWebNotification"

    private weak var webView: WKWebView?
    let token: String
    let webViewInstanceID: UUID
    private let isCurrentGeneration: @MainActor (WKWebView, UUID) -> Bool
    private let onPayload: @MainActor (BrowserWebNotificationPayload, UUID) -> Void

    init(
        webView: WKWebView,
        token: String,
        webViewInstanceID: UUID,
        isCurrentGeneration: @escaping @MainActor (WKWebView, UUID) -> Bool,
        onPayload: @escaping @MainActor (BrowserWebNotificationPayload, UUID) -> Void
    ) {
        self.webView = webView
        self.token = token
        self.webViewInstanceID = webViewInstanceID
        self.isCurrentGeneration = isCurrentGeneration
        self.onPayload = onPayload
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let webView, message.webView === webView else { return }

        MainActor.assumeIsolated {
            let generationIsCurrent = isCurrentGeneration(webView, webViewInstanceID)
            let origin = message.frameInfo.securityOrigin
            guard let payload = BrowserWebNotificationPayload.validated(
                body: message.body,
                expectedToken: token,
                originScheme: origin.protocol,
                originHost: origin.host,
                isMainFrame: message.frameInfo.isMainFrame,
                isCurrentWebView: message.webView === webView,
                isCurrentGeneration: generationIsCurrent
            ) else { return }
            onPayload(payload, webViewInstanceID)
        }
    }
}
