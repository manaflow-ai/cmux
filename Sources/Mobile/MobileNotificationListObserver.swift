import Combine
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
/// Observing the `@Published notifications` source of truth means every mutation
/// surface (a notification firing, the Mac marking read, the phone marking read
/// via the RPC, mark-all-read) syncs automatically, without per-call emit hooks.
/// `markRead` replaces the array, so read-state changes are covered by this one
/// publisher.
///
/// Uses Combine (`$notifications` + `throttle`) deliberately, to stay
/// byte-for-byte consistent with its sibling `MobileWorkspaceListObserver`: the
/// underlying `TerminalNotificationStore` is a Combine `ObservableObject` whose
/// `@Published` array is the only change signal, and the throttle/`latest`
/// burst-collapse behavior is the same one the workspace observer relies on.
@MainActor
final class MobileNotificationListObserver {
    /// How many recent notifications the Mac sends and the observer hashes. Kept
    /// in sync with the phone-side `MobileNotificationsStore.recentLimit`.
    static let recentLimit = 200

    private let store: TerminalNotificationStore
    private var cancellable: AnyCancellable?
    private var lastSummaryHash: Int = 0
    /// Throttle window with `latest: true`, matching the workspace observer: the
    /// first event in a burst emits immediately, later events within the window
    /// collapse to one trailing emit. Hash-diff suppresses no-op rebroadcasts.
    private let throttleMilliseconds: Int = 80

    init(store: TerminalNotificationStore) {
        self.store = store
        attach()
    }

    private func attach() {
        // Unconditional first emit so a freshly-paired client sees the current
        // feed without waiting for the next notification.
        lastSummaryHash = Self.summaryHash(for: store.notifications)
        MobileHostService.shared.emitEvent(topic: "notifications.updated", payload: [:])

        cancellable = store.$notifications
            .throttle(for: .milliseconds(throttleMilliseconds), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] notifications in
                self?.emitIfNeeded(notifications: notifications, force: false)
            }
    }

    private func emitIfNeeded(notifications: [TerminalNotification], force: Bool) {
        let hash = Self.summaryHash(for: notifications)
        if !force, hash == lastSummaryHash {
            return
        }
        lastSummaryHash = hash
        mobileNotificationObserverLog.debug("emitting notifications.updated (hash=\(hash, privacy: .public))")
        MobileHostService.shared.emitEvent(topic: "notifications.updated", payload: [:])
    }

    /// Stable hash of the iOS-facing notification shape: each notification's id
    /// and read-state, in order. A new notification, a removal, or a read-state
    /// flip changes the hash and re-emits; content-only mutations (which do not
    /// happen for an immutable-bodied notification) would not. The recent-N cap
    /// is applied so the hash matches the window the phone actually fetches.
    static func summaryHash(for notifications: [TerminalNotification]) -> Int {
        var hasher = Hasher()
        let recent = notifications
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(recentLimit)
        hasher.combine(recent.count)
        for notification in recent {
            hasher.combine(notification.id)
            hasher.combine(notification.isRead)
        }
        return hasher.finalize()
    }
}
