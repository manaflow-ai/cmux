import CmuxAuthRuntime
import Foundation

/// UserDefaults keys for the phone-forwarding feature. Default OFF: the Mac
/// uploads nothing unless the user explicitly turns it on.
enum PhonePushSettings {
    /// Master gate. When false (default), notifications are never forwarded.
    static let forwardEnabledKey = "forwardNotificationsToPhone"
    /// When true, forward a generic message instead of the real title/body so
    /// terminal content never leaves the Mac.
    static let hideContentKey = "forwardNotificationsHideContent"
}

/// Forwards macOS terminal notifications to the user's iPhone via the cmux web
/// API (`POST /api/notifications/push`), which relays them through APNs. Gated
/// by ``PhonePushSettings/forwardEnabledKey`` (off by default) and only invoked
/// from the not-suppressed desktop-delivery path, so it mirrors what the Mac
/// itself shows. Best-effort and non-blocking.
@MainActor
final class PhonePushClient {
    static let shared = PhonePushClient()

    private let session: URLSession = .shared
    /// Injected once via `configure(auth:)` at app startup. Forwarding is a
    /// best-effort path; until configured, sends are silently skipped.
    private var auth: AuthCoordinator?
    /// Per workspace+surface throttle to defend against notification bursts.
    private var lastSentAt: [String: Date] = [:]
    private static let minInterval: TimeInterval = 1.0

    private init() {}

    /// Inject the auth dependency. Call once at the composition root.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
    }

    static var isForwardingEnabled: Bool {
        UserDefaults.standard.bool(forKey: PhonePushSettings.forwardEnabledKey)
    }

    /// Forward a notification if the user opted in. Captures the fields up front
    /// and performs the network call off the caller's critical path.
    func forward(_ notification: TerminalNotification) {
        guard Self.isForwardingEnabled else { return }

        let key = "\(notification.tabId.uuidString):\(notification.surfaceId?.uuidString ?? "")"
        let now = Date()
        if let last = lastSentAt[key], now.timeIntervalSince(last) < Self.minInterval { return }
        lastSentAt[key] = now

        let hideContent = UserDefaults.standard.bool(forKey: PhonePushSettings.hideContentKey)
        let payload = Payload(
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            workspaceId: notification.tabId.uuidString,
            surfaceId: notification.surfaceId?.uuidString,
            hideContent: hideContent
        )
        Task { await send(payload) }
    }

    private struct Payload: Sendable {
        let title: String
        let subtitle: String
        let body: String
        let workspaceId: String
        let surfaceId: String?
        let hideContent: Bool
    }

    private func send(_ payload: Payload) async {
        guard let auth else { return }
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            return // not signed in → nothing to do
        }
        let teamID = auth.resolvedTeamID

        guard var comps = URLComponents(url: AuthEnvironment.vmAPIBaseURL, resolvingAgainstBaseURL: false) else {
            return
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/api/notifications/push"
        guard let url = comps.url else { return }

        // When hideContent is on, the real terminal title/subtitle/body must
        // never leave the Mac. Send generic placeholders so the request still
        // carries valid, parseable fields while the actual content stays local.
        // workspaceId/surfaceId/hideContent are opaque IDs/flags, not content.
        var bodyDict: [String: Any] = [
            "title": payload.hideContent ? "cmux" : payload.title,
            "subtitle": payload.hideContent ? "" : payload.subtitle,
            "body": payload.hideContent ? "New terminal activity" : payload.body,
            "workspaceId": payload.workspaceId,
            "hideContent": payload.hideContent,
        ]
        if let surfaceId = payload.surfaceId { bodyDict["surfaceId"] = surfaceId }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict, options: [])

        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                NSLog("cmux.phonepush failed status=%d", http.statusCode)
            }
        } catch {
            // best-effort; phone forwarding must never disrupt the Mac.
        }
    }
}
