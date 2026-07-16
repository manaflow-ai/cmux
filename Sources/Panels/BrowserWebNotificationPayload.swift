import Foundation

/// Validated website-notification content accepted from a browser webview.
struct BrowserWebNotificationPayload: Equatable, Sendable {
    static let maximumTitleLength = 256
    static let maximumBodyLength = 4_096

    let title: String
    let body: String
    let hostname: String

    /// Validates an untrusted script-message body and bounds forwarded text.
    static func validated(
        body rawBody: Any,
        expectedToken: String,
        originScheme: String,
        originHost: String,
        isMainFrame: Bool,
        isCurrentWebView: Bool,
        isCurrentGeneration: Bool
    ) -> BrowserWebNotificationPayload? {
        guard isMainFrame, isCurrentWebView, isCurrentGeneration,
              let body = rawBody as? [String: Any],
              let token = body["token"] as? String,
              token == expectedToken,
              let title = body["title"] as? String,
              let notificationBody = body["body"] as? String else {
            return nil
        }

        let scheme = originScheme.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let hostname = originHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !hostname.isEmpty else { return nil }

        return BrowserWebNotificationPayload(
            title: String(title.prefix(maximumTitleLength)),
            body: String(notificationBody.prefix(maximumBodyLength)),
            hostname: hostname
        )
    }
}
