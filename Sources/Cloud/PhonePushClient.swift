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
    /// WHEN forwards happen once the master gate is on: a
    /// ``PhoneForwardingMode`` raw value. Missing/unrecognized values fall
    /// back to ``PhoneForwardingMode/defaultMode`` (only when away).
    static let forwardModeKey = "forwardNotificationsToPhoneMode"
}

/// Refines WHEN notifications are forwarded once
/// ``PhonePushSettings/forwardEnabledKey`` is on. It never widens forwarding:
/// the master toggle stays the opt-in.
enum PhoneForwardingMode: String, CaseIterable {
    /// Forward only while the user is away from this Mac (the default,
    /// including for users who enabled forwarding before this mode existed).
    case onlyWhenAway
    /// Forward every notification regardless of Mac presence.
    case always

    static let defaultMode: PhoneForwardingMode = .onlyWhenAway

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> PhoneForwardingMode {
        guard let raw = defaults.string(forKey: PhonePushSettings.forwardModeKey),
              let mode = PhoneForwardingMode(rawValue: raw)
        else {
            return defaultMode
        }
        return mode
    }
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
    /// Presence source for the "only when away" mode. Injectable for tests.
    var presenceMonitor: MacPresenceMonitor = .live()
    /// Bounds live presence sampling to once per second under bursts.
    private var presenceCache = MacPresenceDecisionCache()

    private init() {}

    /// Inject the auth dependency. Call once at the composition root.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
    }

    static var isForwardingEnabled: Bool {
        UserDefaults.standard.bool(forKey: PhonePushSettings.forwardEnabledKey)
    }

    /// The presence gate: `.onlyWhenAway` drops the forward while the Mac is
    /// actively in use; `.always` ignores presence. Suppressed forwards are
    /// not queued or retried when the Mac later goes away - the push mirrors
    /// "what would buzz the phone right now" - and the Mac-side notification
    /// (unread accounting, notification list) is untouched upstream.
    nonisolated static func shouldForward(
        mode: PhoneForwardingMode,
        presence: MacPresenceMonitor.Decision
    ) -> Bool {
        switch mode {
        case .always:
            return true
        case .onlyWhenAway:
            return !presence.isActive
        }
    }

    /// Forward a notification if the user opted in. Captures the fields up front
    /// and performs the network call off the caller's critical path.
    func forward(_ notification: TerminalNotification) {
        guard Self.isForwardingEnabled else { return }

        // Read-only burst-throttle check FIRST: a dictionary lookup that
        // bounds everything downstream (presence sampling and sends) to one
        // per key per second under notification storms.
        let key = "\(notification.tabId.uuidString):\(notification.surfaceId?.uuidString ?? "")"
        let now = Date()
        if let last = lastSentAt[key], now.timeIntervalSince(last) < Self.minInterval { return }

        // Presence gate, evaluated per notification at delivery time so the
        // phone never receives a suppressed push. `.always` skips presence
        // sampling entirely (`shouldForward` is constant true there). Active
        // (suppressing) decisions are additionally coalesced by the cache, so
        // suppressed bursts (which never consume a throttle slot) stay cheap.
        let mode = PhoneForwardingMode.fromDefaults()
        if mode != .always {
            let presence = presenceCache.decision(from: presenceMonitor)
            guard Self.shouldForward(mode: mode, presence: presence) else {
#if DEBUG
                cmuxDebugLog("phonepush.suppressed reason=macActive verdict=\(presence.verdict)")
#endif
                return
            }
        }

        // The throttle slot is consumed only after the gate passes, so a
        // suppressed notification does not block a forwardable one moments
        // later. Suppressed bursts therefore re-enter this method per
        // notification, but each suppressed pass is O(1) cheap work (defaults
        // read + cache hit): live WindowServer/HID sampling stays bounded to
        // once per cache TTL globally, which is stricter than the per-key
        // bound this throttle provides for sends.
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
