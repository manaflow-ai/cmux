import Foundation
import WebKit

/// Receives and validates compatibility-shim messages from one webview generation.
final class BrowserWebNotificationMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "cmuxWebNotification"

    private weak var webView: WKWebView?
    let token: String
    let webViewInstanceID: UUID
    private let isCurrentGeneration: @MainActor (WKWebView, UUID) -> Bool
    private let onPayload: @MainActor (BrowserWebNotificationPayload, UUID) -> Void
    private let onPermissionRequest: @MainActor (URL, @escaping (Bool) -> Void) -> Void

    init(
        webView: WKWebView,
        token: String,
        webViewInstanceID: UUID,
        isCurrentGeneration: @escaping @MainActor (WKWebView, UUID) -> Bool,
        onPayload: @escaping @MainActor (BrowserWebNotificationPayload, UUID) -> Void,
        onPermissionRequest: @escaping @MainActor (URL, @escaping (Bool) -> Void) -> Void
    ) {
        self.webView = webView
        self.token = token
        self.webViewInstanceID = webViewInstanceID
        self.isCurrentGeneration = isCurrentGeneration
        self.onPayload = onPayload
        self.onPermissionRequest = onPermissionRequest
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let webView, message.webView === webView else {
            replyHandler(nil, "stale_webview")
            return
        }

        MainActor.assumeIsolated {
            let generationIsCurrent = isCurrentGeneration(webView, webViewInstanceID)
            let origin = message.frameInfo.securityOrigin
            guard generationIsCurrent, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  body["token"] as? String == token else {
                replyHandler(nil, "invalid_message")
                return
            }

            if body["type"] as? String == "permission" {
                guard let originURL = Self.originURL(origin) else {
                    replyHandler("denied", nil)
                    return
                }
                onPermissionRequest(originURL) { allowed in
                    replyHandler(allowed ? "granted" : "denied", nil)
                }
                return
            }

            guard body["type"] as? String == "notification",
                  let payload = BrowserWebNotificationPayload.validated(
                      body: body,
                      expectedToken: token,
                      originScheme: origin.protocol,
                      originHost: origin.host,
                      isMainFrame: true,
                      isCurrentWebView: true,
                      isCurrentGeneration: true
                  ) else {
                replyHandler(nil, "invalid_notification")
                return
            }
            onPayload(payload, webViewInstanceID)
            replyHandler("ok", nil)
        }
    }

    private static func originURL(_ origin: WKSecurityOrigin) -> URL? {
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        return components.url
    }
}
