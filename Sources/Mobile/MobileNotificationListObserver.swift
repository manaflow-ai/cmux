import Foundation
import OSLog

private let mobileNotificationObserverLog = Logger(subsystem: "dev.cmux", category: "mobile-notification-observer")

/// Watches `TerminalNotificationStore.notifications` and emits
/// `notifications.updated` to subscribed mobile clients whenever the iOS-facing
/// shape of the notification feed changes (a new notification, or a read-state
/// flip). The phone refetches the recent list via `mobile.notifications.list`
/// in response — the same signal-then-refetch contract the workspace list uses
/// (`MobileWorkspaceListObserver` → `workspace.updated`).
///
/// Observes the store's coalesced notifications stream, then hashes the wire
/// shape.
@MainActor
final class MobileNotificationListObserver {
    private static let eventTopic = "notifications.updated"
    /// How many recent notifications the Mac sends and the observer hashes. Kept
    /// in sync with the phone-side `MobileNotificationsStore.recentLimit`.
    static let recentLimit = 200

    private let store: TerminalNotificationStore
    private var notificationsTask: Task<Void, Never>?
    private var subscriptionTask: Task<Void, Never>?
    private var defaultsTask: Task<Void, Never>?
    private var coalescedEmitTask: Task<Void, Never>?
    private var pendingNotifications: [TerminalNotification]?
    private var lastSummaryHash: Int = 0

    init(store: TerminalNotificationStore) {
        self.store = store
        attach()
    }

    private func attach() {
        // Unconditional first emit so a freshly-paired client sees the current
        // feed without waiting for the next notification.
        lastSummaryHash = Self.summaryHash(for: store.notifications)
        emitCurrentIfSubscribed(force: true)

        notificationsTask = Task { @MainActor [weak self, store] in
            for await notifications in store.notificationsStream() {
                guard let self else { return }
                guard Self.hasSubscribers else { continue }
                self.scheduleCoalescedEmit(notifications: notifications)
            }
        }
        subscriptionTask = Task { @MainActor [weak self] in
            let changes = NotificationCenter.default.notifications(
                named: .mobileHostEventSubscriptionsDidChange
            )
            for await notification in changes {
                guard let self else { return }
                let topics = notification.userInfo?["topics"] as? [String] ?? []
                guard topics.isEmpty || topics.contains(Self.eventTopic) else { continue }
                self.emitCurrentIfSubscribed(force: true)
            }
        }
        defaultsTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: UserDefaults.didChangeNotification,
                object: UserDefaults.standard
            )
            for await _ in notifications {
                guard let self else { return }
                self.emitCurrentIfSubscribed(force: false)
            }
        }
    }

    deinit {
        notificationsTask?.cancel()
        subscriptionTask?.cancel()
        defaultsTask?.cancel()
        coalescedEmitTask?.cancel()
    }

    private static var hasSubscribers: Bool {
        MobileHostService.hasEventSubscribers(topic: eventTopic)
    }

    private func emitCurrentIfSubscribed(force: Bool) {
        guard Self.hasSubscribers else { return }
        emitIfNeeded(notifications: store.notifications, force: force)
    }

    private func scheduleCoalescedEmit(notifications: [TerminalNotification]) {
        pendingNotifications = notifications
        guard coalescedEmitTask == nil else { return }
        coalescedEmitTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            let notifications = pendingNotifications ?? store.notifications
            pendingNotifications = nil
            coalescedEmitTask = nil
            guard Self.hasSubscribers else { return }
            emitIfNeeded(notifications: notifications, force: false)
        }
    }

    private func emitIfNeeded(notifications: [TerminalNotification], force: Bool) {
        let hash = Self.summaryHash(for: notifications)
        if !force, hash == lastSummaryHash {
            return
        }
        lastSummaryHash = hash
        mobileNotificationObserverLog.debug("emitting notifications.updated (hash=\(hash, privacy: .public))")
        MobileHostService.shared.emitEvent(topic: Self.eventTopic, payload: [:])
    }

    /// Stable hash of the full iOS-facing notification shape. The recent-N cap
    /// is applied so the hash matches the window the phone actually fetches.
    static func summaryHash(for notifications: [TerminalNotification]) -> Int {
        var hasher = Hasher()
        let recent = TerminalController.mobileRecentNotifications(notifications, limit: recentLimit)
        let hideContent = UserDefaults.standard.bool(forKey: PhonePushSettings.hideContentKey)
        hasher.combine(hideContent)
        hasher.combine(recent.count)
        for notification in recent {
            let content = TerminalController.mobileNotificationFeedContent(notification, hideContent: hideContent)
            hasher.combine(notification.id)
            hasher.combine(notification.tabId)
            hasher.combine(notification.surfaceId)
            hasher.combine(content.title)
            hasher.combine(content.subtitle)
            hasher.combine(content.body)
            hasher.combine(notification.createdAt.timeIntervalSince1970)
            hasher.combine(notification.isRead)
        }
        return hasher.finalize()
    }
}
