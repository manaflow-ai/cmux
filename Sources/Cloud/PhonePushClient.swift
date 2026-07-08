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

/// Forwards macOS terminal notifications to the user's iPhone via the cmux web
/// API (`POST /api/notifications/push`), which relays them through APNs. Gated
/// by ``PhonePushSettings/forwardEnabledKey`` (off by default) and only invoked
/// from the not-suppressed desktop-delivery path, so it mirrors what the Mac
/// itself shows. Best-effort and non-blocking.
///
/// Two push kinds share the transport: the visible banner mirror
/// (``forward(_:badgeCount:)``) and the silent dismiss/badge push
/// (``forwardDismissed(ids:badgeCount:)``), the cold lane of Mac→iOS
/// dismiss-sync that reaches every registered device, attached or not.
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
    /// Bounds live presence sampling under suppressed (active-Mac) bursts;
    /// see `MacPresenceDecisionCache` for the staleness invariant.
    private var presenceCache = MacPresenceDecisionCache()

    /// Dismissed ids waiting for the drain task, deduped at send time. Bursts
    /// coalesce structurally: ids accumulate while one send is in flight and the
    /// drain loop ships whatever piled up next, chunked to the server's cap, so
    /// "Clear All" (one emit) is one push and N rapid swipes are at most a
    /// couple — no timers involved.
    private var pendingDismissedIDs: [String] = []
    /// The freshest authoritative unread count; later dismisses overwrite it so
    /// the badge that ships is always the latest total.
    private var pendingDismissBadgeCount = 0
    private var dismissDrainTask: Task<Void, Never>?
    /// Keep each dismiss push within the server's `MAX_PUSH_DISMISS_IDS`.
    private static let maxDismissIDsPerPush = 64

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

    /// Whether a banner forward for this delivery would currently pass the
    /// enable + presence gate, ignoring the per-tab/surface burst throttle.
    ///
    /// The superseded-banner buffering decision in
    /// ``TerminalNotificationStore`` keys on this so it matches the real send
    /// decision in ``forward(_:badgeCount:)``: only the throttle is a
    /// legitimate "defer and flush on the next successful forward" case. When
    /// forwarding is off or the `.onlyWhenAway` presence gate suppresses the
    /// replacement (Mac active), no replacement push is coming, so the store
    /// must emit the superseded dismiss immediately rather than stash it for a
    /// forward that will never happen. Returns `false` when forwarding is off
    /// or the presence gate currently suppresses delivery; `true` otherwise.
    func willForwardReplacement(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: PhonePushSettings.forwardEnabledKey) else { return false }
        let mode = PhoneForwardingMode.fromDefaults(defaults)
        if mode == .always { return true }
        let presence = presenceCache.decision(from: presenceMonitor)
        return Self.shouldForward(mode: mode, presence: presence)
    }

    /// Forward a notification if the user opted in. Captures the fields up front
    /// and performs the network call off the caller's critical path.
    /// - Parameter badgeCount: The authoritative unread-notification total at
    ///   send time; the server emits it as `aps.badge` so the phone's icon badge
    ///   is always SET to the computed total (never incremented locally).
    /// - Returns: Whether the banner push was actually queued for sending —
    ///   `false` when forwarding is off or the per-tab/surface throttle dropped
    ///   it. The store keys the superseded-banner dismiss on this, so a
    ///   throttled replacement can never strand the phone with no banner for a
    ///   still-unread notification.
    @discardableResult
    func forward(_ notification: TerminalNotification, badgeCount: Int) -> Bool {
        guard Self.isForwardingEnabled else { return false }

        // Read-only burst-throttle check FIRST: a dictionary lookup that
        // bounds everything downstream (presence sampling and sends) to one
        // per key per second under notification storms.
        let key = "\(notification.tabId.uuidString):\(notification.surfaceId?.uuidString ?? "")"
        let now = Date()
        if let last = lastSentAt[key], now.timeIntervalSince(last) < Self.minInterval { return false }

        // Presence gate, decided per notification at delivery time so the
        // phone never receives a suppressed push. `.always` skips sampling
        // entirely (`shouldForward` is constant true there). Forwarding
        // decisions are always freshly sampled (the user-return transition
        // gates the very next notification); suppressed bursts are bounded
        // by the active-decision cache instead of the send throttle, because
        // suppression must not consume a send slot. See
        // `MacPresenceDecisionCache` for the explicit staleness invariant.
        // A suppressed forward queues no banner push, so it reports `false`
        // like a throttled one: the store must not dismiss the superseded
        // banner when no replacement is coming.
        let mode = PhoneForwardingMode.fromDefaults()
        if mode != .always {
            let presence = presenceCache.decision(from: presenceMonitor)
            guard Self.shouldForward(mode: mode, presence: presence) else {
#if DEBUG
                cmuxDebugLog("phonepush.suppressed reason=macActive verdict=\(presence.verdict)")
#endif
                return false
            }
        }

        // The throttle slot is consumed only after the gate passes, so a
        // suppressed notification does not block a forwardable one moments
        // later.
        lastSentAt[key] = now

        let hideContent = UserDefaults.standard.bool(forKey: PhonePushSettings.hideContentKey)
        let payload = PhonePushPayload(
            kind: .notify,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            workspaceId: notification.tabId.uuidString,
            surfaceId: notification.surfaceId?.uuidString,
            macDeviceId: MobileHostIdentity.deviceID(),
            notificationId: notification.id.uuidString,
            notificationIds: [],
            badgeCount: badgeCount,
            hideContent: hideContent
        )
        Task { await send(payload) }
        return true
    }

    /// The cold lane of Mac→iOS dismiss-sync: mirror a Mac-side dismiss through
    /// a silent APNs push (`content-available` + `aps.badge` + the dismissed
    /// ids). Sent unconditionally — the push route fans out to every registered
    /// device token, so a live-attached phone (which already handled the peer
    /// event; the push is an idempotent no-op there) must not starve an offline
    /// second device.
    /// The system applies the badge immediately; banner removal happens when iOS
    /// grants the (strictly budgeted) background wake, and the app-foreground
    /// reconcile sweep heals anything iOS deferred. Carries only opaque UUIDs.
    func forwardDismissed(ids: [String], badgeCount: Int) {
        guard Self.isForwardingEnabled, !ids.isEmpty else { return }
        pendingDismissedIDs.append(contentsOf: ids)
        pendingDismissBadgeCount = badgeCount
        guard dismissDrainTask == nil else { return }
        dismissDrainTask = Task { [weak self] in
            await self?.drainPendingDismisses()
        }
    }

    private func drainPendingDismisses() async {
        defer { dismissDrainTask = nil }
        while !pendingDismissedIDs.isEmpty {
            var seen = Set<String>()
            let deduped = pendingDismissedIDs.filter { seen.insert($0).inserted }
            let chunk = Array(deduped.prefix(Self.maxDismissIDsPerPush))
            pendingDismissedIDs = Array(deduped.dropFirst(Self.maxDismissIDsPerPush))
            await send(PhonePushPayload(
                kind: .dismiss,
                title: "",
                subtitle: "",
                body: "",
                workspaceId: nil,
                surfaceId: nil,
                macDeviceId: nil,
                notificationId: nil,
                notificationIds: chunk,
                badgeCount: pendingDismissBadgeCount,
                hideContent: false
            ))
        }
    }

    private func send(_ payload: PhonePushPayload) async {
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
        // Ids, the badge count, and hideContent are opaque values, not content.
        var bodyDict: [String: Any] = [
            "kind": payload.kind.rawValue,
            "badgeCount": payload.badgeCount,
            "hideContent": payload.hideContent,
        ]
        switch payload.kind {
        case .notify:
            bodyDict["title"] = payload.hideContent ? "cmux" : payload.title
            bodyDict["subtitle"] = payload.hideContent ? "" : payload.subtitle
            bodyDict["body"] = payload.hideContent ? "New terminal activity" : payload.body
            if let workspaceId = payload.workspaceId { bodyDict["workspaceId"] = workspaceId }
            if let surfaceId = payload.surfaceId { bodyDict["surfaceId"] = surfaceId }
            if let macDeviceId = payload.macDeviceId { bodyDict["macDeviceId"] = macDeviceId }
            // Opaque UUID, not content: safe to send even when hideContent is on.
            if let notificationId = payload.notificationId { bodyDict["notificationId"] = notificationId }
        case .dismiss:
            bodyDict["notificationIds"] = payload.notificationIds
        }

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
                NSLog("cmux.phonepush failed kind=%@ status=%d", payload.kind.rawValue, http.statusCode)
            }
        } catch {
            // best-effort; phone forwarding must never disrupt the Mac.
        }
    }
}
