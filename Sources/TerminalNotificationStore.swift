import CmuxFoundation
import AppKit
import Foundation
import os
import UserNotifications
import Bonsplit
import CmuxSettings

nonisolated let terminalNotificationLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification"
)

private final class TerminalNotificationFeedStorage {
    var oldestFirst: [TerminalNotification]
    private(set) var startOffset: Int
    private var discardedContentBytes: Int

    init(newestFirst: [TerminalNotification] = []) {
        oldestFirst = Array(newestFirst.reversed())
        startOffset = 0
        discardedContentBytes = 0
    }

    private init(activeOldestFirst: [TerminalNotification]) {
        oldestFirst = activeOldestFirst
        startOffset = 0
        discardedContentBytes = 0
    }

    var count: Int {
        oldestFirst.count - startOffset
    }

    func appendNewest(_ notification: TerminalNotification) {
        oldestFirst.append(notification)
    }

    func appendNewestEvictingOldest(
        _ notification: TerminalNotification,
        count evictionCount: Int,
        compactingAfter maxOffset: Int,
        compactingAfterDiscardedBytes maxDiscardedBytes: Int
    ) -> (evicted: [TerminalNotification], replacementStorage: TerminalNotificationFeedStorage?)? {
        guard evictionCount > 0 else {
            appendNewest(notification)
            return ([], nil)
        }
        guard count >= evictionCount else { return nil }
        let nextStartOffset = startOffset + evictionCount
        let evicted = Array(oldestFirst[startOffset..<nextStartOffset])
        let evictedBytes = evicted.reduce(0) {
            $0 + TerminalNotificationStore.notificationContentByteCount($1)
        }
        if nextStartOffset >= maxOffset ||
            discardedContentBytes + evictedBytes >= maxDiscardedBytes {
            var active = Array(oldestFirst[nextStartOffset...])
            active.append(notification)
            return (evicted, TerminalNotificationFeedStorage(activeOldestFirst: active))
        }
        startOffset = nextStartOffset
        discardedContentBytes += evictedBytes
        oldestFirst.append(notification)
        return (evicted, nil)
    }
}

/// A frozen-count, newest-first view over append-optimized feed storage.
/// Existing snapshots remain valid when a newer notification is appended;
/// non-append mutations replace the backing storage instead of editing it.
struct TerminalNotificationFeed: RandomAccessCollection, Equatable, ExpressibleByArrayLiteral {
    typealias Index = Int
    typealias Element = TerminalNotification

    fileprivate let storage: TerminalNotificationFeedStorage
    private let startOffset: Int
    let count: Int

    fileprivate init(storage: TerminalNotificationFeedStorage) {
        self.storage = storage
        startOffset = storage.startOffset
        count = storage.count
    }

    init(arrayLiteral elements: TerminalNotification...) {
        storage = TerminalNotificationFeedStorage(newestFirst: elements)
        startOffset = 0
        count = elements.count
    }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(position: Int) -> TerminalNotification {
        precondition(indices.contains(position))
        return storage.oldestFirst[startOffset + count - position - 1]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.elementsEqual(rhs)
    }
}

// UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:) and
// removePendingNotificationRequests(withIdentifiers:) perform synchronous XPC to
// usernoted under the hood. When usernoted is slow, this blocks the calling thread
// indefinitely. These helpers dispatch the calls off the main thread so they never
// freeze the UI.
extension UNUserNotificationCenter {
    private static let removalQueue = DispatchQueue(
        label: "com.cmuxterm.notification-removal",
        qos: .utility
    )

    func removeDeliveredNotificationsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func removePendingNotificationRequestsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

enum NotificationBadgeSettings {
    static let dockBadgeEnabledKey = "notificationDockBadgeEnabled"
    static let defaultDockBadgeEnabled = true

    static func isDockBadgeEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: dockBadgeEnabledKey) == nil {
            return defaultDockBadgeEnabled
        }
        return defaults.bool(forKey: dockBadgeEnabledKey)
    }
}

enum NotificationPaneRingSettings {
    static let enabledKey = "notificationPaneRingEnabled"
    static let defaultEnabled = true
}

enum NotificationPaneFlashSettings {
    static let enabledKey = "notificationPaneFlashEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }
}

enum TaggedRunBadgeSettings {
    static let environmentKey = "CMUX_TAG"
    private static let maxTagLength = 10

    static func normalizedTag(from env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        normalizedTag(env[environmentKey])
    }

    static func normalizedTag(_ rawTag: String?) -> String? {
        guard var tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            return nil
        }
        if tag.count > maxTagLength {
            tag = String(tag.prefix(maxTagLength))
        }
        return tag
    }
}

enum AppFocusState {
    static var overrideIsFocused: Bool?

    static func isAppActive() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        return NSApp.isActive
    }

    static func isAppFocused() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        guard NSApp.isActive else { return false }
        guard let keyWindow = NSApp.keyWindow, keyWindow.isKeyWindow else { return false }
        // Only treat the app as "focused" for notification suppression when a main terminal window
        // is key. If Settings/About/debug panels are key, we still want notifications to show.
        if let raw = keyWindow.identifier?.rawValue {
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        }
        return false
    }
}

enum NotificationAuthorizationState: Equatable, Sendable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral

    var statusLabel: String {
        switch self {
        case .unknown, .notDetermined:
            return "Not Requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .provisional:
            return "Deliver Quietly"
        case .ephemeral:
            return "Temporary"
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}

@MainActor
final class TerminalNotificationStore: ObservableObject {
    struct TabSurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    struct NotificationIndexes {
        var ids = Set<UUID>()
        var unreadCount = 0
        var unreadCountByTabId: [UUID: Int] = [:]
        var unreadCountByTabSurface: [TabSurfaceKey: Int] = [:]
        var unreadByTabSurface = Set<TabSurfaceKey>()
        var latestByTabId: [UUID: TerminalNotification] = [:]
        var latestByTabSurface: [TabSurfaceKey: TerminalNotification] = [:]
    }

    static let shared = TerminalNotificationStore()
    let notificationHookCache = CmuxNotificationHookCache()

    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"
    nonisolated static let retargetsToLiveSurfaceOwnerUserInfoKey = "retargetsToLiveSurfaceOwner"

    /// Mobile-host event topic the Mac emits when one or more delivered
    /// notifications are dismissed/cleared on this Mac, so an attached phone can
    /// clear the matching banners it is mirroring. Payload carries the stable
    /// notification ids plus the authoritative unread count
    /// (`["ids": [String], "unread_count": Int]`) — never any terminal content —
    /// so dismiss-sync is safe even with phone-forward hideContent on.
    static let dismissedEventTopic = "notification.dismissed"

    /// Mobile-host event topic carrying the authoritative unread-notification
    /// count (`["unread_count": Int]`) whenever it changes. The phone SETS its
    /// app-icon badge to this absolute total (never local ±1 arithmetic), so any
    /// drift self-heals on the next event. Emitted from the same chokepoint that
    /// refreshes the Mac Dock badge, so every mutation lane is covered.
    static let badgeEventTopic = "notification.badge"
    static let maximumNotificationFeedCount = 20_000
    nonisolated static let maximumNotificationTitleBytes = 8 * 1024
    nonisolated static let maximumNotificationSubtitleBytes = 16 * 1024
    nonisolated static let maximumNotificationBodyBytes = 64 * 1024
    nonisolated static let maximumNotificationFeedContentBytes = 8 * 1024 * 1024
#if DEBUG
    static var notificationFeedCompactionOffsetForTesting: Int?
#endif

    private static var notificationFeedCompactionOffset: Int {
#if DEBUG
        notificationFeedCompactionOffsetForTesting ?? maximumNotificationFeedCount
#else
        maximumNotificationFeedCount
#endif
    }
    private static let notificationFeedCompactionDiscardedBytes = maximumNotificationFeedContentBytes / 4

    /// The number of unread notification *entries* — the count the iOS app icon
    /// badge mirrors. The phone's banners mirror notification entries, so its
    /// badge counts exactly those. (The Mac Dock badge additionally counts
    /// workspace-level manual unread indicators, which have no phone banner.)
    var unreadNotificationCount: Int { indexes.unreadCount }

    /// Recently dismissed/cleared notification ids, kept so the phone's
    /// foreground reconcile sweep can classify a delivered banner as "handled
    /// here" even after the entry left the store entirely (remove / clear-all
    /// paths). Bounded ring: oldest evicted past ``dismissedTombstoneCapacity``.
    /// Holds opaque UUIDs only, never content.
    ///
    /// Write-through persisted to `UserDefaults` (lazy-loaded on first use) so
    /// the reconcile lane survives a Mac relaunch: session restore keeps
    /// notification ids stable, so a phone that reconnects after this app
    /// restarted must still learn that a banner it holds was dismissed here
    /// even when the silent dismiss push never reached it.
    private var dismissedTombstoneIDs = Set<UUID>()
    private var dismissedTombstoneOrder: [UUID] = []
    private var dismissedTombstonesLoaded = false
    private static let dismissedTombstoneCapacity = 512
    static let dismissedTombstoneDefaultsKey = "cmux.notifications.dismissedTombstoneIds"
    private var retainedSupersededBannerIDs = Set<UUID>()
    private var retainedSupersededBannerIDsLoaded = false
    private var retainedSupersededBannerPersistenceDeltas: [String] = []
    private var retainedSupersededBannerDeltaPersistenceInFlight = false
    private var retainedSupersededBannerDeltaPersistenceDirty = false
    private var retainedSupersededBannerSnapshotPersistenceInFlight = false
    private var retainedSupersededBannerSnapshotPersistenceDirty = false
    private static let retainedSupersededBannerPersistenceQueue = DispatchQueue(
        label: "com.cmux.notification.retained-superseded-banner-persistence",
        qos: .utility
    )
    static let retainedSupersededBannerDefaultsKey = "cmux.notifications.retainedSupersededBannerIds"
    static let retainedSupersededBannerDeltaDefaultsKey = "cmux.notifications.retainedSupersededBannerIdDeltas"
    private static let retainedSupersededBannerDeltaCompactionThreshold = 512

    private func loadDismissedTombstonesIfNeeded() {
        guard !dismissedTombstonesLoaded else { return }
        dismissedTombstonesLoaded = true
        let stored = UserDefaults.standard.stringArray(forKey: Self.dismissedTombstoneDefaultsKey) ?? []
        for id in stored.compactMap({ UUID(uuidString: $0) }) where dismissedTombstoneIDs.insert(id).inserted {
            dismissedTombstoneOrder.append(id)
        }
    }

    private func recordDismissTombstones(ids: [UUID]) {
        loadDismissedTombstonesIfNeeded()
        for id in ids where dismissedTombstoneIDs.insert(id).inserted {
            dismissedTombstoneOrder.append(id)
        }
        let overflow = dismissedTombstoneOrder.count - Self.dismissedTombstoneCapacity
        if overflow > 0 {
            for stale in dismissedTombstoneOrder.prefix(overflow) {
                dismissedTombstoneIDs.remove(stale)
            }
            dismissedTombstoneOrder.removeFirst(overflow)
        }
        UserDefaults.standard.set(
            dismissedTombstoneOrder.map(\.uuidString),
            forKey: Self.dismissedTombstoneDefaultsKey
        )
    }

    private func removeDismissTombstones(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        loadDismissedTombstonesIfNeeded()
        removeRetainedSupersededBannerIDs(ids: ids)
        let removedIds = Set(ids.filter { dismissedTombstoneIDs.remove($0) != nil })
        guard !removedIds.isEmpty else { return }
        dismissedTombstoneOrder.removeAll { removedIds.contains($0) }
        UserDefaults.standard.set(
            dismissedTombstoneOrder.map(\.uuidString),
            forKey: Self.dismissedTombstoneDefaultsKey
        )
    }

    /// Drop the in-memory tombstone copy so the next use re-reads the persisted
    /// ring — the behavior-test analogue of a process restart.
    func reloadDismissedTombstonesForTesting() {
        dismissedTombstoneIDs.removeAll()
        dismissedTombstoneOrder.removeAll()
        dismissedTombstonesLoaded = false
        retainedSupersededBannerIDs.removeAll()
        retainedSupersededBannerPersistenceDeltas.removeAll()
        retainedSupersededBannerIDsLoaded = false
        retainedSupersededBannerDeltaPersistenceInFlight = false
        retainedSupersededBannerDeltaPersistenceDirty = false
        retainedSupersededBannerSnapshotPersistenceInFlight = false
        retainedSupersededBannerSnapshotPersistenceDirty = false
    }

    private func loadRetainedSupersededBannerIDsIfNeeded() {
        guard !retainedSupersededBannerIDsLoaded else { return }
        retainedSupersededBannerIDsLoaded = true
        let stored = UserDefaults.standard.stringArray(forKey: Self.retainedSupersededBannerDefaultsKey) ?? []
        var ids = Set(stored.compactMap { UUID(uuidString: $0) })
        let deltas = UserDefaults.standard.stringArray(forKey: Self.retainedSupersededBannerDeltaDefaultsKey) ?? []
        for delta in deltas {
            Self.applyRetainedSupersededBannerDelta(delta, to: &ids)
        }
        retainedSupersededBannerIDs = ids
        retainedSupersededBannerPersistenceDeltas = deltas
        if deltas.count >= Self.retainedSupersededBannerDeltaCompactionThreshold {
            scheduleRetainedSupersededBannerSnapshotPersistence()
        }
    }

    private nonisolated static func retainedSupersededBannerDelta(id: UUID, isInsertion: Bool) -> String {
        "\(isInsertion ? "+" : "-")\(id.uuidString)"
    }

    private nonisolated static func applyRetainedSupersededBannerDelta(_ delta: String, to ids: inout Set<UUID>) {
        guard let operation = delta.first,
              let id = UUID(uuidString: String(delta.dropFirst())) else { return }
        switch operation {
        case "+":
            ids.insert(id)
        case "-":
            ids.remove(id)
        default:
            break
        }
    }

    private func scheduleRetainedSupersededBannerDeltaPersistence() {
        guard !retainedSupersededBannerDeltaPersistenceInFlight else {
            retainedSupersededBannerDeltaPersistenceDirty = true
            return
        }
        retainedSupersededBannerDeltaPersistenceInFlight = true
        retainedSupersededBannerDeltaPersistenceDirty = false
        let deltas = retainedSupersededBannerPersistenceDeltas
        Self.retainedSupersededBannerPersistenceQueue.async {
            UserDefaults.standard.set(deltas, forKey: Self.retainedSupersededBannerDeltaDefaultsKey)
            Task { @MainActor [weak self] in
                guard let self else { return }
                retainedSupersededBannerDeltaPersistenceInFlight = false
                if retainedSupersededBannerDeltaPersistenceDirty,
                   !retainedSupersededBannerPersistenceDeltas.isEmpty {
                    scheduleRetainedSupersededBannerDeltaPersistence()
                }
            }
        }
    }

    private func scheduleRetainedSupersededBannerSnapshotPersistence() {
        guard !retainedSupersededBannerSnapshotPersistenceInFlight else {
            retainedSupersededBannerSnapshotPersistenceDirty = true
            scheduleRetainedSupersededBannerDeltaPersistence()
            return
        }
        retainedSupersededBannerSnapshotPersistenceInFlight = true
        retainedSupersededBannerSnapshotPersistenceDirty = false
        let ids = retainedSupersededBannerIDs
        retainedSupersededBannerPersistenceDeltas.removeAll()
        Self.retainedSupersededBannerPersistenceQueue.async {
            let snapshot = ids.map(\.uuidString).sorted()
            let defaults = UserDefaults.standard
            defaults.set(snapshot, forKey: Self.retainedSupersededBannerDefaultsKey)
            defaults.removeObject(forKey: Self.retainedSupersededBannerDeltaDefaultsKey)
            Task { @MainActor [weak self] in
                guard let self else { return }
                retainedSupersededBannerSnapshotPersistenceInFlight = false
                if retainedSupersededBannerSnapshotPersistenceDirty ||
                    retainedSupersededBannerPersistenceDeltas.count >= Self.retainedSupersededBannerDeltaCompactionThreshold {
                    scheduleRetainedSupersededBannerSnapshotPersistence()
                } else if !retainedSupersededBannerPersistenceDeltas.isEmpty {
                    scheduleRetainedSupersededBannerDeltaPersistence()
                }
            }
        }
    }

    private func persistRetainedSupersededBannerIDChanges(inserted: [UUID] = [], removed: [UUID] = []) {
        guard !inserted.isEmpty || !removed.isEmpty else { return }
        let deltas = inserted.map { Self.retainedSupersededBannerDelta(id: $0, isInsertion: true) } +
            removed.map { Self.retainedSupersededBannerDelta(id: $0, isInsertion: false) }
        retainedSupersededBannerPersistenceDeltas.append(contentsOf: deltas)
        if retainedSupersededBannerPersistenceDeltas.count >= Self.retainedSupersededBannerDeltaCompactionThreshold ||
            deltas.count >= Self.retainedSupersededBannerDeltaCompactionThreshold {
            scheduleRetainedSupersededBannerSnapshotPersistence()
        } else {
            scheduleRetainedSupersededBannerDeltaPersistence()
        }
    }

    private func recordRetainedSupersededBannerIDs(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        loadRetainedSupersededBannerIDsIfNeeded()
        var inserted: [UUID] = []
        for id in ids where retainedSupersededBannerIDs.insert(id).inserted {
            inserted.append(id)
        }
        persistRetainedSupersededBannerIDChanges(inserted: inserted)
    }

    private func removeRetainedSupersededBannerIDs(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        loadRetainedSupersededBannerIDsIfNeeded()
        var removed: [UUID] = []
        for id in ids where retainedSupersededBannerIDs.remove(id) != nil {
            removed.append(id)
        }
        persistRetainedSupersededBannerIDChanges(removed: removed)
    }

    private func reconcileRetainedSupersededBannerIDs(retainedIDs: Set<UUID>) {
        loadRetainedSupersededBannerIDsIfNeeded()
        let reconciled = retainedSupersededBannerIDs.intersection(retainedIDs)
        guard reconciled != retainedSupersededBannerIDs else { return }
        let removed = Array(retainedSupersededBannerIDs.subtracting(reconciled))
        retainedSupersededBannerIDs = reconciled
        persistRetainedSupersededBannerIDChanges(removed: removed)
    }

    /// Phone-banner dismissals for superseded notifications, deferred until the
    /// replacement banner push for the same tab/surface is actually queued.
    /// ``PhonePushClient/forward(_:badgeCount:)`` throttles per tab/surface, so
    /// dismissing the old banner unconditionally could strand the phone with no
    /// banner at all for a still-unread notification when the replacement push
    /// was dropped. When a replacement forward is expected, the store stashes
    /// the superseded ids here and emits the dismiss only after the push is
    /// queued, making clear+replace atomic from the phone's perspective; when
    /// no replacement will be forwarded at all, `recordNotification` emits the
    /// dismiss immediately instead of stashing. While deferred, the phone keeps
    /// the older (stale-text) banner — the pre-existing throttle behavior — and
    /// the reconcile sweep still classifies the ids correctly because they are
    /// tombstoned at supersede time.
    private var supersededPhoneDismissBuffer = SupersededPhoneDismissBuffer()
    private var externalBannerOwnership = ExternalNotificationBannerOwnership()

    /// Classify which of the phone's delivered banner ids have been handled on
    /// this Mac: still in the store and read, or recently removed (tombstoned).
    /// Ids this Mac has never seen are NOT reported handled — they may belong to
    /// a different paired Mac — so the phone leaves those banners alone. A
    /// retained unread row with a tombstone represents superseded history, so
    /// its older phone banner is handled. Explicitly marking a row unread
    /// removes its tombstone and resurrects that banner identity.
    func reconcileHandledNotificationIDs(deliveredIDs: [UUID]) -> [String] {
        guard !deliveredIDs.isEmpty else { return [] }
        loadDismissedTombstonesIfNeeded()
        loadRetainedSupersededBannerIDsIfNeeded()
        var readIDs = Set<UUID>()
        var knownIDs = Set<UUID>()
        for notification in notifications {
            knownIDs.insert(notification.id)
            if notification.isRead { readIDs.insert(notification.id) }
        }
        return deliveredIDs
            .filter { id in
                if knownIDs.contains(id) {
                    return readIDs.contains(id) ||
                        dismissedTombstoneIDs.contains(id) ||
                        retainedSupersededBannerIDs.contains(id)
                }
                return dismissedTombstoneIDs.contains(id)
            }
            .map(\.uuidString)
    }

    /// Forwards a dismiss/clear to the user's phone. Call only from the
    /// change-confirmed branch of a user-driven read/clear/remove path, so the
    /// Mac→iOS→Mac echo can't loop. Session restore / surface rebind paths must
    /// not call this unless two owner keys collide: ordinary churn preserves
    /// the phone banner, while a collision must dismiss the displaced owner.
    ///
    /// Two lanes share this chokepoint: the instant peer event for a
    /// live-attached phone, and a silent APNs badge push (the cold lane) so a
    /// pocketed phone still drops the banner and badge. Both carry the
    /// authoritative unread count.
    ///
    /// The cold lane is sent UNCONDITIONALLY (never gated on live subscribers):
    /// the push route fans out to every iOS device token registered for the
    /// user, so one live-attached phone must not starve an offline second
    /// device of its dismiss. The push is idempotent on a device that already
    /// handled the live event — removing an already-removed banner is a no-op
    /// and the badge is an absolute SET — and bursts coalesce in
    /// ``PhonePushClient/forwardDismissed(ids:badgeCount:)``.
    private func emitNotificationsDismissed(ids: [String]) {
        guard !ids.isEmpty else { return }
        recordDismissTombstones(ids: ids.compactMap { UUID(uuidString: $0) })
        let unreadCount = indexes.unreadCount
        // Live lane: nonisolated static fan-out; short-circuits when no phone is
        // subscribed.
        MobileHostService.emitEvent(
            topic: Self.dismissedEventTopic,
            payload: ["ids": ids, "unread_count": unreadCount]
        )
        // Cold lane: mirror the dismiss through APNs for every registered
        // device, attached or not (no-op unless phone forwarding is on).
        PhonePushClient.shared.forwardDismissed(ids: ids, badgeCount: unreadCount)
    }

    /// A user-driven dismiss emit that also carries any stale superseded-banner
    /// ids the caller drained from ``supersededPhoneDismissBuffer``. Once the
    /// current notification for a tab/surface is read/cleared/removed, no
    /// replacement push will ever flush those stragglers (their forward was
    /// throttled), so they must ride along with the triggering emit or an
    /// offline phone keeps the stale banner until its next reconcile.
    private func emitNotificationsDismissed(ids: [String], drainedSuperseded: [String]) {
        guard !drainedSuperseded.isEmpty else {
            emitNotificationsDismissed(ids: ids)
            return
        }
        let extra = drainedSuperseded.filter { !ids.contains($0) }
        emitNotificationsDismissed(ids: ids + extra)
    }

    /// The last unread count pushed over ``badgeEventTopic``, so the chokepoint
    /// only emits on real transitions.
    private var lastEmittedPhoneBadgeCount: Int?

    /// Pushes the authoritative unread count to an attached phone whenever it
    /// changes. Runs from ``refreshUnreadPresentation()`` — the same chokepoint
    /// that refreshes the Mac Dock badge — so every mutation lane (markRead,
    /// markUnread, record, restore, clear) keeps the phone badge correct without
    /// per-call-site emits. Cheap when nothing is attached (subscriber
    /// short-circuit inside `emitEvent`).
    private func emitUnreadBadgeEventIfChanged() {
        let count = indexes.unreadCount
        guard count != lastEmittedPhoneBadgeCount else { return }
        lastEmittedPhoneBadgeCount = count
        MobileHostService.emitEvent(
            topic: Self.badgeEventTopic,
            payload: ["unread_count": count]
        )
    }

    enum AuthorizationRequestOrigin: String {
        case notificationDelivery = "notification_delivery"
        case settingsButton = "settings_button"
        case settingsTest = "settings_test"
    }

    private enum NotificationMutationHint {
        case insertion(TerminalNotification)
        case insertionEvicting(inserted: TerminalNotification, evicted: [TerminalNotification])
        case readState(before: TerminalNotification, after: TerminalNotification)
    }

    private struct NotificationInsertionCommit {
        let evicted: [TerminalNotification]
    }

    /// Every accepted notification, once per stable id, newest first. Equal
    /// timestamps use ascending UUID text as the deterministic tie break.
    private var notificationFeedStorage = TerminalNotificationFeedStorage()
    private var notificationFeedContentByteCount = 0
    @Published private(set) var notificationFeedRevision: UInt64 = 0
    var notifications: TerminalNotificationFeed {
        TerminalNotificationFeed(storage: notificationFeedStorage)
    }
    private var deferredUnreadNavigationIds: [UUID] = []
    private var unreadNavigationNotifications: [TerminalNotification] = []
    private var unreadNavigationProjectionIsDirty = true

    var notificationsForUnreadNavigation: [TerminalNotification] {
        if unreadNavigationProjectionIsDirty { rebuildUnreadNavigationNotifications() }
        return unreadNavigationNotifications
    }

    private func rebuildUnreadNavigationNotifications() {
        unreadNavigationProjectionIsDirty = false
        guard !deferredUnreadNavigationIds.isEmpty else {
            unreadNavigationNotifications = Array(notifications)
            return
        }
        let deferredIds = Set(deferredUnreadNavigationIds)
        var ordered = notifications.filter { !deferredIds.contains($0.id) }
        let notificationById = Self.indexByIdPreservingFirst(notifications)
        ordered.append(contentsOf: deferredUnreadNavigationIds.compactMap { notificationById[$0] })
        unreadNavigationNotifications = ordered
    }
    @Published private(set) var notificationMenuSnapshot = NotificationMenuSnapshotBuilder.make(notifications: [])
    /// Coalesced, equality-guarded per-workspace unread projection for the
    /// sidebar. The workspace list observes THIS instead of the whole store so
    /// high-frequency notification churn that does not change a workspace's
    /// badge count or latest-message text never republishes to the sidebar.
    /// This is the boundary that keeps the workspace list off the store's hot
    /// publish path (issue #2586 class of sidebar re-render spins). Owned (not
    /// `@Published`) so its updates stay independent of the store's own
    /// `objectWillChange`.
    let sidebarUnread = SidebarUnreadModel()
    // Workspace-level unread drives sidebar workspace badges; pane-level manual
    // unread remains owned by Workspace.manualUnreadPanelIds.
    @Published private(set) var manualUnreadWorkspaceIds: Set<UUID> = [] {
        didSet { refreshUnreadPresentation() }
    }
    @Published private(set) var panelDerivedUnreadWorkspaceIds: Set<UUID> = [] {
        didSet { refreshUnreadPresentation() }
    }
    @Published private(set) var restoredUnreadWorkspaceIds: Set<UUID> = [] {
        didSet { refreshUnreadPresentation() }
    }
    @Published private(set) var focusedReadIndicatorByTabId: [UUID: UUID] = [:] {
        didSet {
            // The sidebar/pane read-indicator presentation derives from this map
            // (see hasVisibleNotificationIndicator); keep the coalesced
            // SidebarUnreadModel in sync when it changes on its own.
            guard focusedReadIndicatorByTabId != oldValue else { return }
            refreshUnreadPresentation()
        }
    }
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown
    private var suppressNotificationDiffPublishing = false

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAutomaticAuthorization = false
    private var hasDeferredAuthorizationRequest = false
    private var hasPromptedForSettings = false
    private var userDefaultsObserver: NSObjectProtocol?
    private let settingsPromptWindowRetryDelay: TimeInterval = 0.5
    private let settingsPromptWindowRetryLimit = 20
    private var notificationSettingsWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    private var notificationSettingsAlertFactory: () -> NSAlert = {
        NSAlert()
    }
    private var notificationSettingsScheduler: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void = {
        delay,
        block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }
    private var notificationSettingsURLOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    private var notificationDeliveryHandler: (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void = {
        store,
        notification,
        effects in
        store.scheduleUserNotification(notification, effects: effects)
    }
    var nativeNotificationDeliveryHooks = NativeNotificationDeliveryHooks()
    private var suppressedNotificationFeedbackHandler: (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void = {
        store,
        notification,
        effects in
        store.playSuppressedNotificationFeedback(for: notification, effects: effects)
    }
    struct NotificationHookFailureThrottleKey: Hashable {
        let hookId: String
        let sourcePath: String?
    }

    private static let notificationHookFailureThrottle: TimeInterval = 300
    var lastNotificationDateByCooldownKey: [String: Date] = [:]
    private var notificationCooldownReservations = NotificationCooldownReservations()
    var lastNotificationHookFailureDateByKey: [NotificationHookFailureThrottleKey: Date] = [:]
    private var indexes = NotificationIndexes()
    private let inFlightPolicyRequests = TerminalNotificationPolicyInFlightStore()

    private init() {
        indexes = Self.buildIndexes(for: notifications)
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDockBadge()
            }
        }
        refreshDockBadge()
        refreshAuthorizationStatus()
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    var unreadCount: Int {
        indexes.unreadCount + workspaceUnreadIndicatorCount
    }

    var workspaceUnreadIndicatorIds: Set<UUID> {
        manualUnreadWorkspaceIds
            .union(panelDerivedUnreadWorkspaceIds)
            .union(restoredUnreadWorkspaceIds)
    }

    private var workspaceUnreadIndicatorCount: Int {
        workspaceUnreadIndicatorIds.count
    }

    private func refreshUnreadPresentation() {
        let nextMenuSnapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notifications,
            workspaceUnreadIndicatorCount: workspaceUnreadIndicatorCount,
            cachedUnreadNotificationCount: indexes.unreadCount
        )
        if notificationMenuSnapshot != nextMenuSnapshot {
            notificationMenuSnapshot = nextMenuSnapshot
        }
        sidebarUnread.apply(
            totalUnreadCount: unreadCount,
            summaries: buildSidebarUnreadSummaries(),
            unreadSurfaceKeys: Set(indexes.unreadByTabSurface.map {
                SidebarSurfaceUnreadKey(workspaceId: $0.tabId, surfaceId: $0.surfaceId)
            }),
            focusedReadIndicatorByWorkspaceId: focusedReadIndicatorByTabId,
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIds
        )
        refreshDockBadge()
        emitUnreadBadgeEventIfChanged()
    }

    private func refreshUnreadPresentation(
        changedWorkspaceIds: Set<UUID>,
        changedSurfaceKeys: Set<SidebarSurfaceUnreadKey>
    ) {
        guard !changedWorkspaceIds.isEmpty || !changedSurfaceKeys.isEmpty else {
            refreshUnreadPresentation()
            return
        }
        let nextMenuSnapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notifications,
            workspaceUnreadIndicatorCount: workspaceUnreadIndicatorCount,
            cachedUnreadNotificationCount: indexes.unreadCount
        )
        if notificationMenuSnapshot != nextMenuSnapshot {
            notificationMenuSnapshot = nextMenuSnapshot
        }
        var changedSummaries: [UUID: SidebarWorkspaceUnreadSummary] = [:]
        var removedSummaryIds: Set<UUID> = []
        for id in changedWorkspaceIds {
            if let summary = sidebarUnreadSummary(forWorkspaceId: id) {
                changedSummaries[id] = summary
            } else {
                removedSummaryIds.insert(id)
            }
        }
        var insertedSurfaceKeys: Set<SidebarSurfaceUnreadKey> = []
        var removedSurfaceKeys: Set<SidebarSurfaceUnreadKey> = []
        for key in changedSurfaceKeys {
            if hasUnreadNotification(forTabId: key.workspaceId, surfaceId: key.surfaceId) {
                insertedSurfaceKeys.insert(key)
            } else {
                removedSurfaceKeys.insert(key)
            }
        }
        sidebarUnread.applyIncremental(
            totalUnreadCount: unreadCount,
            changedSummaries: changedSummaries,
            removedSummaryIds: removedSummaryIds,
            insertedUnreadSurfaceKeys: insertedSurfaceKeys,
            removedUnreadSurfaceKeys: removedSurfaceKeys,
            focusedReadIndicatorByWorkspaceId: focusedReadIndicatorByTabId,
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIds
        )
        refreshDockBadge()
        emitUnreadBadgeEventIfChanged()
    }

    private static func sidebarUnreadSurfaceKeys(for notification: TerminalNotification) -> Set<SidebarSurfaceUnreadKey> {
        Set(unreadIndexKeys(for: notification).map {
            SidebarSurfaceUnreadKey(workspaceId: $0.tabId, surfaceId: $0.surfaceId)
        })
    }

    private static func recordChangedUnreadPresentationScope(
        for notification: TerminalNotification,
        workspaceIds: inout Set<UUID>,
        surfaceKeys: inout Set<SidebarSurfaceUnreadKey>
    ) {
        workspaceIds.insert(notification.tabId)
        surfaceKeys.formUnion(sidebarUnreadSurfaceKeys(for: notification))
    }

    /// Builds the per-workspace unread summaries the sidebar renders. Mirrors
    /// `unreadCount(forTabId:)` and `latestNotification(forTabId:)` so the
    /// coalesced model is a drop-in source for the sidebar's per-row reads.
    /// Only workspaces with a non-default summary are included; absent entries
    /// resolve to `(0, nil)` via `SidebarUnreadModel.summary(forWorkspaceId:)`.
    private func buildSidebarUnreadSummaries() -> [UUID: SidebarWorkspaceUnreadSummary] {
        var ids = Set(indexes.unreadCountByTabId.keys)
        ids.formUnion(indexes.latestByTabId.keys)
        ids.formUnion(workspaceUnreadIndicatorIds)
        var result: [UUID: SidebarWorkspaceUnreadSummary] = [:]
        result.reserveCapacity(ids.count)
        for id in ids {
            let count = unreadCount(forTabId: id)
            let latestText: String? = indexes.latestByTabId[id].flatMap { notification in
                let text = notification.body.isEmpty ? notification.title : notification.body
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if count == 0, latestText == nil { continue }
            result[id] = SidebarWorkspaceUnreadSummary(
                unreadCount: count,
                latestNotificationText: latestText
            )
        }
        return result
    }

    private func sidebarUnreadSummary(forWorkspaceId id: UUID) -> SidebarWorkspaceUnreadSummary? {
        let count = unreadCount(forTabId: id)
        let latestText: String? = indexes.latestByTabId[id].flatMap { notification in
            let text = notification.body.isEmpty ? notification.title : notification.body
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard count != 0 || latestText != nil else { return nil }
        return SidebarWorkspaceUnreadSummary(
            unreadCount: count,
            latestNotificationText: latestText
        )
    }

    private func logAuthorization(_ message: String) {
#if DEBUG
        cmuxDebugLog("notification.auth \(message)")
#endif
        terminalNotificationLogger.info("Authorization \(message, privacy: .private)")
    }

    private static func authorizationStatusLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "refresh status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel)"
                )
            }
        }
    }

    func requestAuthorizationFromSettings() {
        logAuthorization("settings request tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsButton) { _, _ in }
    }

    func openNotificationSettings() {
        guard let url = Self.notificationSettingsURL(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        logAuthorization("open settings url=\(url.absoluteString)")
        notificationSettingsURLOpener(url)
    }

    static func notificationSettingsURL(bundleIdentifier: String?) -> URL? {
        if let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty,
           let encodedBundleIdentifier = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(encodedBundleIdentifier)"
            )
        }
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    func sendSettingsTestNotification() {
        logAuthorization("settings test tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsTest) { [weak self] authorized, _ in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "cmux test notification"
            content.body = "Desktop notifications are enabled."
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier

            let request = UNNotificationRequest(
                identifier: "cmux.settings.test.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    terminalNotificationLogger.error(
                        "Failed to schedule test notification error=\(error.localizedDescription, privacy: .private)"
                    )
                    self.logAuthorization("settings test schedule failed error=\(error.localizedDescription)")
                } else {
                    self.logAuthorization("settings test schedule succeeded")
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    func handleApplicationDidBecomeActive() {
        logAuthorization("app became active deferred=\(hasDeferredAuthorizationRequest)")
        if hasDeferredAuthorizationRequest {
            hasDeferredAuthorizationRequest = false
            ensureAuthorization(origin: .settingsButton) { _, _ in }
            return
        }
        refreshAuthorizationStatus()
    }

    @discardableResult
    private func setWorkspaceManualUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        var nextIds = manualUnreadWorkspaceIds
        let didChange: Bool
        if isUnread {
            didChange = nextIds.insert(tabId).inserted
        } else {
            didChange = nextIds.remove(tabId) != nil
        }
        guard didChange else { return false }
        manualUnreadWorkspaceIds = nextIds
        return true
    }

    private func clearWorkspaceManualUnread() {
        guard !manualUnreadWorkspaceIds.isEmpty else { return }
        manualUnreadWorkspaceIds = []
    }

    @discardableResult
    private func setPanelDerivedWorkspaceUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        var nextIds = panelDerivedUnreadWorkspaceIds
        let didChange: Bool
        if isUnread {
            didChange = nextIds.insert(tabId).inserted
        } else {
            didChange = nextIds.remove(tabId) != nil
        }
        guard didChange else { return false }
        panelDerivedUnreadWorkspaceIds = nextIds
        return true
    }

    private func clearPanelDerivedWorkspaceUnread() {
        guard !panelDerivedUnreadWorkspaceIds.isEmpty else { return }
        panelDerivedUnreadWorkspaceIds = []
    }

    private func clearWorkspacePanelUnread(forTabId tabId: UUID) {
        guard let appDelegate = AppDelegate.shared else { return }
        let workspace = appDelegate.workspaceFor(tabId: tabId) ??
            appDelegate.tabManager?.tabs.first(where: { $0.id == tabId })
        workspace?.clearAllPanelUnreadIndicatorsForWorkspaceRead()
    }

    private func clearAllWorkspacePanelUnread(forTabIds tabIds: Set<UUID>) {
        for tabId in tabIds {
            clearWorkspacePanelUnread(forTabId: tabId)
        }
    }

    @discardableResult
    private func setWorkspaceRestoredUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        var nextIds = restoredUnreadWorkspaceIds
        let didChange: Bool
        if isUnread {
            didChange = nextIds.insert(tabId).inserted
        } else {
            didChange = nextIds.remove(tabId) != nil
        }
        guard didChange else { return false }
        restoredUnreadWorkspaceIds = nextIds
        return true
    }

    private func clearWorkspaceRestoredUnread() {
        guard !restoredUnreadWorkspaceIds.isEmpty else { return }
        restoredUnreadWorkspaceIds = []
    }

    func hasManualUnread(forTabId tabId: UUID) -> Bool { manualUnreadWorkspaceIds.contains(tabId) }

    func hasPanelDerivedUnread(forTabId tabId: UUID) -> Bool { panelDerivedUnreadWorkspaceIds.contains(tabId) }

    func hasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool { restoredUnreadWorkspaceIds.contains(tabId) }

    func hasDismissibleState(forTabId tabId: UUID) -> Bool {
        (indexes.unreadCountByTabId[tabId] ?? 0) > 0 ||
            focusedReadIndicatorByTabId[tabId] != nil ||
            manualUnreadWorkspaceIds.contains(tabId) ||
            panelDerivedUnreadWorkspaceIds.contains(tabId) ||
            restoredUnreadWorkspaceIds.contains(tabId) ||
            inFlightPolicyRequests.hasPendingRequest(forTabId: tabId)
    }

    func hasPendingNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        if surfaceId == nil { return inFlightPolicyRequests.hasPendingRequest(forTabId: tabId) }
        return inFlightPolicyRequests.hasPendingRequest(forTabId: tabId, surfaceId: surfaceId)
    }

    @discardableResult
    func setPanelDerivedUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        setPanelDerivedWorkspaceUnread(isUnread, forTabId: tabId)
    }

    @discardableResult
    func restoreUnreadIndicator(forTabId tabId: UUID) -> Bool {
        setWorkspaceRestoredUnread(true, forTabId: tabId)
    }

    @discardableResult
    func clearRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool {
        setWorkspaceRestoredUnread(false, forTabId: tabId)
    }

    @discardableResult
    func clearManualUnread(forTabId tabId: UUID) -> Bool {
        setWorkspaceManualUnread(false, forTabId: tabId)
    }

    // Per-workspace badges treat workspace indicators as unread activity;
    // summing these counts can exceed indexes.unreadCount.
    func unreadCount(forTabId tabId: UUID) -> Int {
        let hasWorkspaceUnreadIndicator = manualUnreadWorkspaceIds.contains(tabId) ||
            panelDerivedUnreadWorkspaceIds.contains(tabId) ||
            restoredUnreadWorkspaceIds.contains(tabId)
        return (indexes.unreadCountByTabId[tabId] ?? 0) + (hasWorkspaceUnreadIndicator ? 1 : 0)
    }

    func workspaceIsUnread(forTabId tabId: UUID) -> Bool {
        unreadCount(forTabId: tabId) > 0
    }

    func canMarkWorkspaceRead(forTabIds tabIds: [UUID]) -> Bool {
        tabIds.contains { workspaceIsUnread(forTabId: $0) }
    }

    func canMarkWorkspaceUnread(forTabIds tabIds: [UUID]) -> Bool {
        tabIds.contains { !workspaceIsUnread(forTabId: $0) }
    }

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        indexes.unreadByTabSurface.contains(TabSurfaceKey(tabId: tabId, surfaceId: surfaceId))
    }

    func hasUnreadNotificationRequiringPaneFlash(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        notifications.contains { notification in
            notification.matches(tabId: tabId, surfaceId: surfaceId) &&
                !notification.isRead &&
                notification.paneFlash
        }
    }

    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) ||
            (focusedReadIndicatorByTabId[tabId].map { $0 == surfaceId } ?? false)
    }

    func latestNotification(forTabId tabId: UUID) -> TerminalNotification? {
        indexes.latestByTabId[tabId]
    }

    var notificationWorkspaceIds: Set<UUID> { Set(indexes.latestByTabId.keys) }

    func notifications(forTabId tabId: UUID, surfaceId: UUID?) -> [TerminalNotification] {
        notifications.filter { $0.matches(tabId: tabId, surfaceId: surfaceId) }
    }

    func clearLatestNotification(forTabId tabId: UUID) {
        guard let latestNotification = indexes.latestByTabId[tabId] else { return }
        remove(id: latestNotification.id)
    }

    func focusedReadIndicatorSurfaceId(forTabId tabId: UUID) -> UUID? {
        focusedReadIndicatorByTabId[tabId]
    }

    /// Reserves dismissible policy work before desktop-notification hook lookup suspends.
    func beginDesktopNotificationHookResolution(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        body: String
    ) -> UUID {
        let policyContext = makeNotificationPolicyContext(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: "",
            body: body,
            retargetsToLiveSurfaceOwner: true,
            resolvedHooks: []
        )
        return inFlightPolicyRequests.register(
            policyContext.request,
            generation: TerminalMutationBus.shared.notificationGenerationSnapshot(),
            onDiscard: {}
        )
    }

    /// Abandons a desktop-hook reservation that cannot reach final delivery.
    func abortDesktopNotificationHookResolution(_ policyRequestId: UUID) {
        inFlightPolicyRequests.discard(policyRequestId)
    }

    func addNotification(
        id: UUID = UUID(),
        acceptedAt: Date = Date(),
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        retargetsToLiveSurfaceOwner: Bool = true,
        cooldownKey: String? = nil,
        cooldownInterval: TimeInterval? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        notificationGeneration: UInt64? = nil,
        resolvedHooks: [CmuxResolvedNotificationHook]? = nil,
        preRegisteredPolicyRequestId: UUID? = nil
    ) {
        let routedKey: QueuedTerminalNotificationKey
        if retargetsToLiveSurfaceOwner {
            routedKey = TerminalMutationBus.shared.routedNotificationKey(
                tabId: tabId,
                surfaceId: surfaceId
            )
        } else {
            routedKey = QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId)
        }
#if DEBUG
        cmuxDebugLog(
            "notification.store.add workspace=\(routedKey.tabId.uuidString.prefix(8)) surface=\(routedKey.surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count) cooldown=\(cooldownKey == nil ? 0 : 1)"
        )
#endif
        let resolvedCooldownInterval: TimeInterval?
        if let cooldownInterval, cooldownInterval.isFinite, cooldownInterval > 0 {
            resolvedCooldownInterval = cooldownInterval
        } else {
            resolvedCooldownInterval = nil
        }
        if let cooldownKey,
           let resolvedCooldownInterval,
           let lastNotificationDate = lastNotificationDateByCooldownKey[cooldownKey],
           acceptedAt.timeIntervalSince(lastNotificationDate) < resolvedCooldownInterval {
#if DEBUG
            cmuxDebugLog(
                "notification.store.add.skip workspace=\(routedKey.tabId.uuidString.prefix(8)) surface=\(routedKey.surfaceId?.uuidString.prefix(8) ?? "nil") reason=cooldown"
            )
#endif
            if let preRegisteredPolicyRequestId {
                abortDesktopNotificationHookResolution(preRegisteredPolicyRequestId)
            }
            return
        }
        let cooldownReservation = notificationCooldownReservations.reserve(
            key: cooldownKey,
            interval: resolvedCooldownInterval,
            acceptedAt: acceptedAt,
            dates: &lastNotificationDateByCooldownKey
        )

        let policyContext = makeNotificationPolicyContext(
            tabId: routedKey.tabId,
            surfaceId: routedKey.surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            resolvedHooks: resolvedHooks
        )
        if policyContext.hooks.isEmpty, preRegisteredPolicyRequestId == nil {
            if cooldownReservation == nil {
                applyNotification(
                    id: id,
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    acceptedAt: acceptedAt,
                    cooldownReservation: nil,
                    scrollPosition: policyContext.scrollPosition,
                    clickAction: clickAction
                )
                return
            }
        }
        guard let policyRequestId = prepareNotificationPolicyRequestId(
            preRegisteredPolicyRequestId: preRegisteredPolicyRequestId,
            request: policyContext.request,
            notificationGeneration: notificationGeneration,
            cooldownReservation: cooldownReservation
        ) else {
            return
        }
        guard !policyContext.hooks.isEmpty else {
            completePolicyRequest(
                policyRequestId,
                id: id,
                request: policyContext.request,
                effects: TerminalNotificationPolicyEffects(),
                acceptedAt: acceptedAt,
                cooldownReservation: cooldownReservation,
                scrollPosition: policyContext.scrollPosition,
                clickAction: clickAction
            )
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let authorizedHooks = await NotificationPolicyHookAuthorizer.authorize(
                policyContext.hooks,
                globalConfigPath: policyContext.globalConfigPath
            )
            guard !Task.isCancelled else { return }
            guard !authorizedHooks.isEmpty else {
                self.completePolicyRequest(
                    policyRequestId,
                    id: id,
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    acceptedAt: acceptedAt,
                    cooldownReservation: cooldownReservation,
                    scrollPosition: policyContext.scrollPosition,
                    clickAction: clickAction
                )
                return
            }

            let result = await TerminalNotificationPolicyEngine.evaluate(
                request: policyContext.request,
                hooks: authorizedHooks
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let envelope):
                self.completePolicyRequest(
                    policyRequestId,
                    id: id,
                    request: policyContext.request,
                    envelope: envelope,
                    acceptedAt: acceptedAt,
                    cooldownReservation: cooldownReservation,
                    scrollPosition: policyContext.scrollPosition,
                    clickAction: clickAction
                )
            case .failure(let failure):
                self.completePolicyRequest(
                    policyRequestId,
                    id: id,
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    acceptedAt: acceptedAt,
                    cooldownReservation: cooldownReservation,
                    scrollPosition: policyContext.scrollPosition,
                    clickAction: clickAction
                )
                self.reportNotificationHookFailure(failure)
            }
        }
        inFlightPolicyRequests.attach(task: task, to: policyRequestId)
    }

    private func completePolicyRequest(
        _ policyRequestId: UUID,
        id: UUID,
        request: TerminalNotificationPolicyRequest,
        envelope: TerminalNotificationPolicyEnvelope,
        acceptedAt: Date,
        cooldownReservation: NotificationCooldownReservations.Reservation?,
        scrollPosition: TerminalNotificationScrollPosition?,
        clickAction: TerminalNotificationClickAction?
    ) {
        inFlightPolicyRequests.complete(policyRequestId) { [weak self] registeredRequest in
            let claimedRequest = request.replacingLocation(
                tabId: registeredRequest.tabId,
                surfaceId: registeredRequest.surfaceId,
                panelId: registeredRequest.panelId
            )
            self?.applyNotification(
                id: id,
                request: claimedRequest,
                envelope: envelope,
                acceptedAt: acceptedAt,
                cooldownReservation: cooldownReservation,
                scrollPosition: scrollPosition,
                clickAction: clickAction,
                policyRequestId: nil
            )
        }
    }

    private func completePolicyRequest(
        _ policyRequestId: UUID,
        id: UUID,
        request: TerminalNotificationPolicyRequest,
        effects: TerminalNotificationPolicyEffects,
        acceptedAt: Date,
        cooldownReservation: NotificationCooldownReservations.Reservation?,
        scrollPosition: TerminalNotificationScrollPosition?,
        clickAction: TerminalNotificationClickAction?
    ) {
        inFlightPolicyRequests.complete(policyRequestId) { [weak self] registeredRequest in
            let claimedRequest = request.replacingLocation(
                tabId: registeredRequest.tabId,
                surfaceId: registeredRequest.surfaceId,
                panelId: registeredRequest.panelId
            )
            self?.applyNotification(
                id: id,
                request: claimedRequest,
                effects: effects,
                acceptedAt: acceptedAt,
                cooldownReservation: cooldownReservation,
                scrollPosition: scrollPosition,
                clickAction: clickAction,
                policyRequestId: nil
            )
        }
    }

    private struct NotificationPolicyContext: Sendable {
        let request: TerminalNotificationPolicyRequest
        let scrollPosition: TerminalNotificationScrollPosition?
        let hooks: [CmuxResolvedNotificationHook]
        let globalConfigPath: String?
    }

    private func prepareNotificationPolicyRequestId(
        preRegisteredPolicyRequestId: UUID?,
        request: TerminalNotificationPolicyRequest,
        notificationGeneration: UInt64?,
        cooldownReservation: NotificationCooldownReservations.Reservation?
    ) -> UUID? {
        let onDiscard: @MainActor @Sendable () -> Void = { [weak self] in
            self?.restoreCooldownReservation(cooldownReservation)
        }
        if let preRegisteredPolicyRequestId {
            guard inFlightPolicyRequests.updateOnDiscard(
                onDiscard,
                cooldownKey: cooldownReservation?.key,
                for: preRegisteredPolicyRequestId
            ) else {
                restoreCooldownReservation(cooldownReservation)
                return nil
            }
            return preRegisteredPolicyRequestId
        }
        return inFlightPolicyRequests.register(
            request,
            generation: notificationGeneration
                ?? TerminalMutationBus.shared.notificationGenerationSnapshot(),
            cooldownKey: cooldownReservation?.key,
            onDiscard: onDiscard
        )
    }

    private func commitCooldownReservation(
        _ reservation: NotificationCooldownReservations.Reservation?,
        at date: Date
    ) {
        notificationCooldownReservations.commit(
            reservation,
            at: date,
            dates: &lastNotificationDateByCooldownKey
        )
    }

    private func restoreCooldownReservation(_ reservation: NotificationCooldownReservations.Reservation?) {
        notificationCooldownReservations.restore(
            reservation,
            dates: &lastNotificationDateByCooldownKey
        )
    }

    private func hasCommittedCooldown(
        _ reservation: NotificationCooldownReservations.Reservation?,
        at acceptedAt: Date
    ) -> Bool {
        guard let reservation,
              let lastNotificationDate = lastNotificationDateByCooldownKey[reservation.key] else {
            return false
        }
        return acceptedAt.timeIntervalSince(lastNotificationDate) < reservation.interval
    }

    private func makeNotificationPolicyContext(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        retargetsToLiveSurfaceOwner: Bool,
        resolvedHooks: [CmuxResolvedNotificationHook]?
    ) -> NotificationPolicyContext {
        let normalizedText = Self.normalizedNotificationText(
            title: title,
            subtitle: subtitle,
            body: body
        )
        let appDelegate = AppDelegate.shared
        let context = appDelegate?.contextContainingTabId(tabId)
        let tabManager = context?.tabManager ?? appDelegate?.tabManagerFor(tabId: tabId) ?? appDelegate?.tabManager
        let cmuxConfigStore = context?.cmuxConfigStore
        let workspace = tabManager?.workspacesById[tabId]
        let focusedSurfaceId = tabManager?.focusedSurfaceId(for: tabId)
        let isActiveTab = tabManager?.selectedTabId == tabId
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        let cwd = workspace?.surfaceTabBarDirectory
            ?? workspace?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let panelId: UUID? = surfaceId.flatMap { surfaceId in
            if workspace?.panels[surfaceId] != nil {
                return surfaceId
            }
            return workspace?.panelIdFromSurfaceId(TabID(uuid: surfaceId))
        }
        let scrollPosition: TerminalNotificationScrollPosition?
        if surfaceId != nil {
            scrollPosition = appDelegate?.terminalNotificationScrollPosition(
                tabId: tabId,
                surfaceId: surfaceId,
                panelId: panelId
            )
        } else {
            scrollPosition = nil
        }

        return NotificationPolicyContext(
            request: TerminalNotificationPolicyRequest(
                tabId: tabId,
                surfaceId: surfaceId,
                panelId: panelId,
                retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
                title: normalizedText.title,
                subtitle: normalizedText.subtitle,
                body: normalizedText.body,
                cwd: cwd,
                isAppFocused: isAppFocused,
                isFocusedPanel: isFocusedPanel
            ),
            scrollPosition: scrollPosition,
            hooks: resolvedHooks ?? cmuxConfigStore?.notificationHooks(
                startingFrom: workspace?.isRemoteWorkspace == true ? nil : cwd
            ) ?? [],
            globalConfigPath: cmuxConfigStore?.globalConfigPath
        )
    }

    private func applyNotification(
        id: UUID,
        request: TerminalNotificationPolicyRequest,
        envelope: TerminalNotificationPolicyEnvelope,
        acceptedAt: Date,
        cooldownReservation: NotificationCooldownReservations.Reservation?,
        scrollPosition: TerminalNotificationScrollPosition?,
        clickAction: TerminalNotificationClickAction?,
        policyRequestId: UUID?
    ) {
        let payload = envelope.notification
        let normalizedPayload = Self.normalizedNotificationText(
            title: payload.title,
            subtitle: payload.subtitle,
            body: payload.body
        )
        applyNotification(
            id: id,
            request: TerminalNotificationPolicyRequest(
                tabId: request.tabId,
                surfaceId: request.surfaceId,
                panelId: request.panelId,
                retargetsToLiveSurfaceOwner: request.retargetsToLiveSurfaceOwner,
                title: normalizedPayload.title,
                subtitle: normalizedPayload.subtitle,
                body: normalizedPayload.body,
                cwd: request.cwd,
                isAppFocused: request.isAppFocused,
                isFocusedPanel: request.isFocusedPanel
            ),
            effects: envelope.effects,
            acceptedAt: acceptedAt,
            cooldownReservation: cooldownReservation,
            scrollPosition: scrollPosition,
            clickAction: clickAction,
            policyRequestId: policyRequestId
        )
    }

    private func applyNotification(
        id: UUID,
        request: TerminalNotificationPolicyRequest,
        effects: TerminalNotificationPolicyEffects,
        acceptedAt: Date,
        cooldownReservation: NotificationCooldownReservations.Reservation?,
        scrollPosition: TerminalNotificationScrollPosition?,
        clickAction: TerminalNotificationClickAction?,
        policyRequestId: UUID? = nil
    ) {
        guard let claimedRequest = inFlightPolicyRequests.claim(
            policyRequestId,
            applying: request
        ) else { return }
        guard let request = notificationPolicyRequestAtLiveOwner(claimedRequest) else {
            restoreCooldownReservation(cooldownReservation)
            return
        }
        guard !hasCommittedCooldown(cooldownReservation, at: acceptedAt) else {
            restoreCooldownReservation(cooldownReservation)
            return
        }
        let normalizedText = Self.normalizedNotificationText(
            title: request.title,
            subtitle: request.subtitle,
            body: request.body
        )
        let notification = TerminalNotification(
            id: id,
            tabId: request.tabId,
            surfaceId: request.surfaceId,
            panelId: request.panelId,
            retargetsToLiveSurfaceOwner: request.retargetsToLiveSurfaceOwner,
            title: normalizedText.title,
            subtitle: normalizedText.subtitle,
            body: normalizedText.body,
            createdAt: acceptedAt,
            isRead: !effects.markUnread,
            paneFlash: effects.paneFlash,
            scrollPosition: scrollPosition,
            clickAction: clickAction
        )

        guard !indexes.ids.contains(notification.id) else {
            restoreCooldownReservation(cooldownReservation)
            return
        }

        let shouldSuppressExternalDelivery = shouldSuppressExternalDelivery(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId
        )

        if effects.record {
            recordNotification(
                notification,
                shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
                effects: effects,
                acceptedAt: acceptedAt,
                cooldownReservation: cooldownReservation
            )
            return
        }

#if DEBUG
        cmuxDebugLog(
            "notification.store.effectsOnly workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") desktop=\(effects.desktop ? 1 : 0) sound=\(effects.sound ? 1 : 0) command=\(effects.command ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0)"
        )
#endif
        if effects.reorderWorkspace,
           UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.reorderOnNotification) {
            AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
                .moveTabToTopForNotification(notification.tabId)
        }
        if hasAnyNotificationEffect(effects) {
            commitCooldownReservation(cooldownReservation, at: acceptedAt)
        } else {
            restoreCooldownReservation(cooldownReservation)
        }
        deliverNotificationSideEffects(
            notification,
            shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
            effects: effects
        )
    }

    private func recordNotification(
        _ notification: TerminalNotification,
        shouldSuppressExternalDelivery: Bool,
        effects: TerminalNotificationPolicyEffects,
        acceptedAt: Date,
        cooldownReservation: NotificationCooldownReservations.Reservation?
    ) {
        if let existingIndicatorSurfaceId = focusedReadIndicatorByTabId[notification.tabId],
           existingIndicatorSurfaceId != notification.surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: notification.tabId)
        }

        if shouldSuppressExternalDelivery, effects.markUnread {
            setFocusedReadIndicator(forTabId: notification.tabId, surfaceId: notification.surfaceId)
        }

        if effects.reorderWorkspace,
           UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.reorderOnNotification) {
            AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
                .moveTabToTopForNotification(notification.tabId)
        }

        let insertionIndex = Self.insertionIndex(for: notification, in: notifications)
        let latestExisting = indexes.latestByTabSurface[
            TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
        ]
        let externalBannerTransition = Self.externalBannerTransition(
            incoming: notification,
            latestExisting: latestExisting
        )
        let bannerOwner = externalBannerOwnership.owner(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId
        )
        let supersededExternalIds = externalBannerTransition.suppressIncoming
            ? []
            : bannerOwner.map { [$0.id.uuidString] } ?? []
        let supersededExternalIdSet = Set(supersededExternalIds)
        let suppressExternalDelivery = shouldSuppressExternalDelivery || externalBannerTransition.suppressIncoming
        guard let insertionCommit = commitInsertion(notification, at: insertionIndex) else {
            restoreCooldownReservation(cooldownReservation)
            return
        }
        setWorkspaceManualUnread(false, forTabId: notification.tabId)
        commitCooldownReservation(cooldownReservation, at: acceptedAt)
#if DEBUG
        cmuxDebugLog(
            "notification.store.record workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") unread=\(!notification.isRead ? 1 : 0) paneFlash=\(notification.paneFlash ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0) total=\(notifications.count)"
        )
#endif
        supersedeExternalBanners(
            ids: supersededExternalIds,
            with: notification,
            shouldSuppressExternalDelivery: suppressExternalDelivery,
            effects: effects
        )
        if !externalBannerTransition.suppressIncoming {
            externalBannerOwnership.clear(tabId: notification.tabId, surfaceId: notification.surfaceId)
            if !suppressExternalDelivery, effects.desktop { externalBannerOwnership.setOwner(notification) }
        }
        dismissEvictedExternalBannerOwners(
            insertionCommit.evicted,
            excluding: supersededExternalIdSet
        )
        deliverNotificationSideEffects(
            notification,
            shouldSuppressExternalDelivery: suppressExternalDelivery,
            effects: effects
        )
    }

    @discardableResult
    private func commitInsertion(
        _ notification: TerminalNotification,
        at index: Int
    ) -> NotificationInsertionCommit? {
        let notificationBytes = Self.notificationContentByteCount(notification)
        if index == 0 {
            var bytesAfterInsertion = notificationFeedContentByteCount + notificationBytes
            var countAfterInsertion = notifications.count + 1
            var evictionCount = 0
            var evicted: [TerminalNotification] = []
            while (countAfterInsertion > Self.maximumNotificationFeedCount
                   || bytesAfterInsertion > Self.maximumNotificationFeedContentBytes),
                  evictionCount < notifications.count {
                let oldest = notifications[notifications.count - evictionCount - 1]
                evicted.append(oldest)
                bytesAfterInsertion -= Self.notificationContentByteCount(oldest)
                countAfterInsertion -= 1
                evictionCount += 1
            }
            if countAfterInsertion <= Self.maximumNotificationFeedCount,
               bytesAfterInsertion <= Self.maximumNotificationFeedContentBytes {
                notificationFeedRevision &+= 1
                if evictionCount == 0 {
                    notificationFeedStorage.appendNewest(notification)
                } else if let eviction = notificationFeedStorage.appendNewestEvictingOldest(
                    notification,
                    count: evictionCount,
                    compactingAfter: Self.notificationFeedCompactionOffset,
                    compactingAfterDiscardedBytes: Self.notificationFeedCompactionDiscardedBytes
                ) {
                    evicted = eviction.evicted
                    if let replacementStorage = eviction.replacementStorage {
                        notificationFeedStorage = replacementStorage
                    }
                } else {
                    return nil
                }
                notificationFeedContentByteCount = bytesAfterInsertion
                notificationFeedDidChange(
                    oldValue: nil,
                    mutation: evicted.isEmpty
                        ? .insertion(notification)
                        : .insertionEvicting(inserted: notification, evicted: evicted)
                )
                return NotificationInsertionCommit(evicted: evicted)
            }
        }
        var updated = Array(notifications)
        updated.insert(notification, at: index)
        let evicted = replaceNotificationFeed(
            updated,
            mutation: .insertion(notification),
            dismissEvictedExternalBannerOwners: false
        )
        guard indexes.ids.contains(notification.id) else {
            dismissEvictedExternalBannerOwners(evicted)
            return nil
        }
        return NotificationInsertionCommit(evicted: evicted)
    }

    private func dismissEvictedExternalBannerOwners(
        _ evicted: [TerminalNotification],
        excluding ids: Set<String> = []
    ) {
        for notification in evicted where !ids.contains(notification.id.uuidString) {
            dismissEvictedExternalBannerOwner(notification)
        }
    }

    private func dismissEvictedExternalBannerOwner(_ evicted: TerminalNotification) {
        guard externalBannerOwnership.owner(
            tabId: evicted.tabId,
            surfaceId: evicted.surfaceId
        )?.id == evicted.id else {
            externalBannerOwnership.clear(id: evicted.id)
            return
        }
        let id = evicted.id.uuidString
        let drainedSuperseded = supersededPhoneDismissesForRowAction(evicted)
        externalBannerOwnership.clear(id: evicted.id)
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id])
        center.removePendingNotificationRequestsOffMain(withIdentifiers: [id])
        emitNotificationsDismissed(ids: [id], drainedSuperseded: drainedSuperseded)
    }

    private static func retainedNotificationFeed(
        from newestFirst: [TerminalNotification]
    ) -> (retained: [TerminalNotification], evicted: [TerminalNotification]) {
        var retained: [TerminalNotification] = []
        retained.reserveCapacity(min(newestFirst.count, maximumNotificationFeedCount))
        var evicted: [TerminalNotification] = []
        var retainedBytes = 0
        for (index, notification) in newestFirst.enumerated() {
            let normalized = normalizedNotificationContent(notification)
            let notificationBytes = notificationContentByteCount(normalized)
            if retained.count < maximumNotificationFeedCount,
               retainedBytes + notificationBytes <= maximumNotificationFeedContentBytes {
                retained.append(normalized)
                retainedBytes += notificationBytes
            } else {
                evicted.append(normalized)
                evicted.append(
                    contentsOf: newestFirst.dropFirst(index + 1).map(normalizedNotificationContent)
                )
                break
            }
        }
        return (retained, evicted)
    }

    nonisolated static func normalizedNotificationText(
        title: String,
        subtitle: String,
        body: String
    ) -> (title: String, subtitle: String, body: String) {
        (
            title: truncatedUTF8(title, maxBytes: maximumNotificationTitleBytes),
            subtitle: truncatedUTF8(subtitle, maxBytes: maximumNotificationSubtitleBytes),
            body: truncatedUTF8(body, maxBytes: maximumNotificationBodyBytes)
        )
    }

    private nonisolated static func normalizedNotificationContent(
        _ notification: TerminalNotification
    ) -> TerminalNotification {
        let normalized = normalizedNotificationText(
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body
        )
        guard normalized.title != notification.title
            || normalized.subtitle != notification.subtitle
            || normalized.body != notification.body else {
            return notification
        }
        return TerminalNotification(
            id: notification.id,
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            panelId: notification.panelId,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            title: normalized.title,
            subtitle: normalized.subtitle,
            body: normalized.body,
            createdAt: notification.createdAt,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            scrollPosition: notification.scrollPosition,
            clickAction: notification.clickAction
        )
    }

    fileprivate nonisolated static func notificationContentByteCount(
        _ notification: TerminalNotification
    ) -> Int {
        notification.title.utf8.count
            + notification.subtitle.utf8.count
            + notification.body.utf8.count
    }

    private nonisolated static func truncatedUTF8(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maxBytes))
        var usedBytes = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard usedBytes + characterBytes <= maxBytes else { break }
            result.append(character)
            usedBytes += characterBytes
        }
        return result
    }

    private func commitReadStateChange(
        from before: TerminalNotification,
        to after: TerminalNotification,
        in updated: [TerminalNotification]
    ) {
        replaceNotificationFeed(updated, mutation: .readState(before: before, after: after))
    }

    @discardableResult
    private func replaceNotificationFeed(
        _ next: [TerminalNotification],
        mutation: NotificationMutationHint? = nil,
        dismissEvictedExternalBannerOwners shouldDismissEvictedExternalBannerOwners: Bool = true
    ) -> [TerminalNotification] {
        let previous = Array(notifications)
        let retained = Self.retainedNotificationFeed(from: next)
        notificationFeedRevision &+= 1
        notificationFeedStorage = TerminalNotificationFeedStorage(newestFirst: retained.retained)
        notificationFeedContentByteCount = retained.retained.reduce(0) {
            $0 + Self.notificationContentByteCount($1)
        }
        reconcileRetainedSupersededBannerIDs(retainedIDs: Set(retained.retained.map(\.id)))
        notificationFeedDidChange(
            oldValue: previous,
            mutation: retained.evicted.isEmpty ? mutation : nil
        )
        if shouldDismissEvictedExternalBannerOwners {
            dismissEvictedExternalBannerOwners(retained.evicted)
        }
        return retained.evicted
    }

    private func notificationFeedDidChange(
        oldValue: [TerminalNotification]?,
        mutation: NotificationMutationHint?
    ) {
        let appliedIncrementally: Bool
        var changedWorkspaceIds: Set<UUID> = []
        var changedSurfaceKeys: Set<SidebarSurfaceUnreadKey> = []
        var shouldRefreshUnreadPresentationFully = false
        switch mutation {
        case .insertion(let inserted):
            Self.insertNotification(inserted, into: &indexes, notifications: notifications)
            Self.recordChangedUnreadPresentationScope(
                for: inserted,
                workspaceIds: &changedWorkspaceIds,
                surfaceKeys: &changedSurfaceKeys
            )
            appliedIncrementally = true
        case .insertionEvicting(let inserted, let evicted):
            Self.insertNotification(
                inserted,
                evicting: evicted,
                into: &indexes,
                notifications: notifications
            )
            let evictedIds = Set(evicted.map(\.id))
            deferredUnreadNavigationIds.removeAll { evictedIds.contains($0) }
            removeRetainedSupersededBannerIDs(ids: Array(evictedIds))
            Self.recordChangedUnreadPresentationScope(
                for: inserted,
                workspaceIds: &changedWorkspaceIds,
                surfaceKeys: &changedSurfaceKeys
            )
            for notification in evicted {
                Self.recordChangedUnreadPresentationScope(
                    for: notification,
                    workspaceIds: &changedWorkspaceIds,
                    surfaceKeys: &changedSurfaceKeys
                )
            }
            appliedIncrementally = true
        case .readState(let before, let after):
            appliedIncrementally = Self.updateReadState(
                from: before,
                to: after,
                in: &indexes,
                notifications: Array(notifications)
            )
            Self.recordChangedUnreadPresentationScope(
                for: before,
                workspaceIds: &changedWorkspaceIds,
                surfaceKeys: &changedSurfaceKeys
            )
            Self.recordChangedUnreadPresentationScope(
                for: after,
                workspaceIds: &changedWorkspaceIds,
                surfaceKeys: &changedSurfaceKeys
            )
        case nil:
            indexes = Self.buildIndexes(for: notifications)
            deferredUnreadNavigationIds.removeAll { !indexes.ids.contains($0) }
            shouldRefreshUnreadPresentationFully = true
            appliedIncrementally = false
        }
        unreadNavigationProjectionIsDirty = true
        if shouldRefreshUnreadPresentationFully {
            refreshUnreadPresentation()
        } else {
            refreshUnreadPresentation(
                changedWorkspaceIds: changedWorkspaceIds,
                changedSurfaceKeys: changedSurfaceKeys
            )
        }
        switch mutation {
        case .insertion(let inserted):
            CmuxEventBus.shared.publishNotificationCreated(inserted, delivery: "store", replacedNotificationIds: [])
        case .insertionEvicting(let inserted, let evicted):
            CmuxEventBus.shared.publishNotificationsRemoved(evicted) {
                CmuxEventBus.shared.publishNotificationCreated(
                    inserted,
                    delivery: "store",
                    replacedNotificationIds: []
                )
            }
        case .readState(let before, let after) where appliedIncrementally:
            if !before.isRead, after.isRead {
                CmuxEventBus.shared.publishNotificationRead(
                    ids: [after.id.uuidString],
                    workspaceId: after.tabId,
                    surfaceId: after.surfaceId
                )
            }
        case .readState where !suppressNotificationDiffPublishing:
            CmuxEventBus.shared.publishNotificationChanges(
                oldValue: oldValue ?? [],
                newValue: Array(notifications)
            )
        case nil where !suppressNotificationDiffPublishing:
            CmuxEventBus.shared.publishNotificationChanges(
                oldValue: oldValue ?? [],
                newValue: Array(notifications)
            )
        default:
            break
        }
    }

    private func supersedeExternalBanners(
        ids: [String],
        with notification: TerminalNotification,
        shouldSuppressExternalDelivery: Bool,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: ids)
        let supersededUUIDs = ids.compactMap { UUID(uuidString: $0) }
        recordRetainedSupersededBannerIDs(ids: supersededUUIDs)

        let key = SupersededPhoneDismissBuffer.key(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId
        )
        let replacementWillForward = !shouldSuppressExternalDelivery
            && effects.desktop
            && PhonePushClient.shared.willForwardReplacement()
        if replacementWillForward {
            recordDismissTombstones(ids: supersededUUIDs)
            supersededPhoneDismissBuffer.stash(ids: ids, forKey: key)
        } else {
            emitNotificationsDismissed(
                ids: ids,
                drainedSuperseded: supersededPhoneDismissBuffer.flush(forKey: key)
            )
        }
    }

    private func shouldSuppressExternalDelivery(tabId: UUID, surfaceId: UUID?) -> Bool {
        let appDelegate = AppDelegate.shared
        let context = appDelegate?.contextContainingTabId(tabId)
        let tabManager = context?.tabManager ?? appDelegate?.tabManagerFor(tabId: tabId) ?? appDelegate?.tabManager
        let focusedSurfaceId = tabManager?.focusedSurfaceId(for: tabId)
        let isActiveTab = tabManager?.selectedTabId == tabId
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        return AppFocusState.isAppFocused() && isActiveTab && isFocusedSurface
    }

    private func deliverNotificationSideEffects(
        _ notification: TerminalNotification,
        shouldSuppressExternalDelivery: Bool,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard effects.desktop || effects.sound || effects.command else {
#if DEBUG
            cmuxDebugLog(
                "notification.store.sideEffects.skip workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") reason=noEffects"
            )
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "notification.store.sideEffects workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") desktop=\(effects.desktop ? 1 : 0) sound=\(effects.sound ? 1 : 0) command=\(effects.command ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0)"
        )
#endif
        if shouldSuppressExternalDelivery {
            suppressedNotificationFeedbackHandler(self, notification, effects)
        } else {
            notificationDeliveryHandler(self, notification, effects)
            // Mirror to the user's iPhone (opt-in, off by default). Only on the
            // desktop-delivery path so it matches what the Mac actually shows;
            // suppressed/focused notifications are not forwarded. The badge is
            // the authoritative unread total at send time (the store was already
            // mutated above, so it includes this notification); the server
            // stamps it as `aps.badge` so the icon badge is SET, not incremented.
            if effects.desktop {
                let queued = PhonePushClient.shared.forward(notification, badgeCount: indexes.unreadCount)
                // Only once the replacement banner push is queued is it safe to
                // clear the superseded banners it replaces (deferred from
                // `recordNotification`); a throttled push leaves them stashed
                // for the next successful forward of this tab/surface.
                if queued {
                    let superseded = supersededPhoneDismissBuffer.flush(
                        forKey: SupersededPhoneDismissBuffer.key(
                            tabId: notification.tabId,
                            surfaceId: notification.surfaceId
                        )
                    )
                    if !superseded.isEmpty {
                        emitNotificationsDismissed(ids: superseded)
                    }
                }
            }
        }
    }

    private func hasAnyNotificationEffect(_ effects: TerminalNotificationPolicyEffects) -> Bool {
        effects.record || effects.desktop || effects.sound || effects.command || effects.reorderWorkspace || effects.markUnread
    }

    func reportNotificationHookFailure(_ failure: TerminalNotificationPolicyFailure) {
        let key = NotificationHookFailureThrottleKey(
            hookId: failure.hookId,
            sourcePath: failure.sourcePath
        )
        let now = Date()
        if let lastDate = lastNotificationHookFailureDateByKey[key],
           now.timeIntervalSince(lastDate) < Self.notificationHookFailureThrottle {
            return
        }
        lastNotificationHookFailureDateByKey[key] = now
        terminalNotificationLogger.error(
            "Notification hook failed hookId=\(failure.hookId, privacy: .public) sourcePath=\(failure.sourcePath ?? "<unknown>", privacy: .private) message=\(failure.message, privacy: .private)"
        )

        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized, _ in
            guard let self, authorized else { return }
            let title = String(
                localized: "notificationHook.failure.title",
                defaultValue: "Notification Hook Failed"
            )
            let format = String(
                localized: "notificationHook.failure.body",
                defaultValue: "cmux used default notification behavior because '%@' failed."
            )
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(format: format, failure.hookId)
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier
            let request = UNNotificationRequest(
                identifier: "cmux.notification-hook.failure.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            self.center.add(request) { error in
                if let error {
                    terminalNotificationLogger.error(
                        "Failed to schedule notification hook failure alert error=\(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }
    }

    func markRead(id: UUID) {
        var updated = Array(notifications)
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard !updated[index].isRead else { return }
        let before = updated[index]
        let drainedSuperseded = supersededPhoneDismissesForRowAction(before)
        updated[index].isRead = true
        deferredUnreadNavigationIds.removeAll { $0 == id }
        commitReadStateChange(from: before, to: updated[index], in: updated)
        externalBannerOwnership.clear(id: id)
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
        emitNotificationsDismissed(ids: [id.uuidString], drainedSuperseded: drainedSuperseded)
    }

    func markUnread(id: UUID) {
        var updated = Array(notifications)
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard updated[index].isRead else { return }
        let before = updated[index]
        let tabId = updated[index].tabId
        updated[index].isRead = false
        removeDismissTombstones(ids: [id])
        deferredUnreadNavigationIds.removeAll { $0 == id }
        commitReadStateChange(from: before, to: updated[index], in: updated)
        // The notification itself now provides the workspace unread indicator. Clear any
        // existing manual or restored workspace unread state for the same tab so we don't
        // double-count it. (Mirrors what markLatestNotificationAsOldestUnread does for the
        // manual flag — restored hints are a one-time signal from a previous session and
        // should also defer to the concrete unread notification.)
        setWorkspaceManualUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
    }

    func markRead(forTabId tabId: UUID) {
        inFlightPolicyRequests.discard(forTabId: tabId, surfaceId: nil)
        var updated = Array(notifications)
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId && !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            let clearedIds = Set(idsToClear.compactMap(UUID.init(uuidString:)))
            deferredUnreadNavigationIds.removeAll { clearedIds.contains($0) }
            replaceNotificationFeed(updated)
        }
        clearFocusedReadIndicator(forTabId: tabId)
        setWorkspaceManualUnread(false, forTabId: tabId)
        clearWorkspacePanelUnread(forTabId: tabId)
        setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
        if !idsToClear.isEmpty {
            externalBannerOwnership.clear(tabId: tabId)
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            emitNotificationsDismissed(
                ids: idsToClear,
                drainedSuperseded: supersededPhoneDismissBuffer.flush(matchingTabId: tabId)
            )
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        inFlightPolicyRequests.discard(forTabId: tabId, surfaceId: surfaceId)
        var updated = Array(notifications)
        var idsToClear: [String] = []
        var supersededDrained = supersededPhoneDismissBuffer.flush(
            forKey: SupersededPhoneDismissBuffer.key(tabId: tabId, surfaceId: surfaceId)
        )
        for index in updated.indices {
            if updated[index].matches(tabId: tabId, surfaceId: surfaceId),
               !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
                supersededDrained.append(contentsOf: supersededPhoneDismissBuffer.flush(
                    forKey: SupersededPhoneDismissBuffer.key(
                        tabId: updated[index].tabId,
                        surfaceId: updated[index].surfaceId
                    )
                ))
            }
        }
        if !idsToClear.isEmpty {
            let clearedIds = Set(idsToClear.compactMap(UUID.init(uuidString:)))
            deferredUnreadNavigationIds.removeAll { clearedIds.contains($0) }
            replaceNotificationFeed(updated)
        }
        clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        if surfaceId == nil {
            clearWorkspacePanelUnread(forTabId: tabId)
            setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
            setWorkspaceRestoredUnread(false, forTabId: tabId)
        }
        if !idsToClear.isEmpty {
            externalBannerOwnership.clear(ids: idsToClear)
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
            emitNotificationsDismissed(ids: idsToClear, drainedSuperseded: supersededDrained)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        setWorkspaceManualUnread(true, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
    }

    @discardableResult
    func markLatestNotificationAsOldestUnread(forTabId tabId: UUID, surfaceId: UUID?) -> UUID? {
        var updated = Array(notifications)
        guard let index = latestNotificationIndex(forTabId: tabId, surfaceId: surfaceId, in: updated) else {
            if surfaceId == nil, !workspaceIsUnread(forTabId: tabId) {
                setWorkspaceManualUnread(true, forTabId: tabId)
            }
            return nil
        }

        let before = updated[index]
        updated[index].isRead = false
        let notificationId = updated[index].id
        removeDismissTombstones(ids: [notificationId])
        deferredUnreadNavigationIds.removeAll { $0 == notificationId }
        deferredUnreadNavigationIds.append(notificationId)
        setWorkspaceManualUnread(false, forTabId: tabId)
        commitReadStateChange(from: before, to: updated[index], in: updated)
        return notificationId
    }

    private func latestNotificationIndex(forTabId tabId: UUID, surfaceId: UUID?, in notifications: [TerminalNotification]) -> Int? {
        if let exactIndex = notifications.firstIndex(where: { $0.matches(tabId: tabId, surfaceId: surfaceId) }) {
            return exactIndex
        }
        if surfaceId != nil,
           let workspaceIndex = notifications.firstIndex(where: { $0.tabId == tabId && $0.surfaceId == nil }) {
            return workspaceIndex
        }
        return notifications.firstIndex(where: { $0.tabId == tabId })
    }

    func setFocusedReadIndicator(forTabId tabId: UUID, surfaceId: UUID?) {
        guard let surfaceId else { return }
        guard focusedReadIndicatorByTabId[tabId] != surfaceId else { return }
        focusedReadIndicatorByTabId[tabId] = surfaceId
    }

    func clearFocusedReadIndicator(forTabId tabId: UUID, surfaceId: UUID? = nil) {
        guard let existingSurfaceId = focusedReadIndicatorByTabId[tabId] else { return }
        guard surfaceId == nil || existingSurfaceId == surfaceId else { return }
        focusedReadIndicatorByTabId.removeValue(forKey: tabId)
    }

    func clearFocusedReadIndicatorIfSurfaceChanged(forTabId tabId: UUID, surfaceId: UUID?) {
        guard let existingSurfaceId = focusedReadIndicatorByTabId[tabId] else { return }
        guard existingSurfaceId != surfaceId else { return }
        focusedReadIndicatorByTabId.removeValue(forKey: tabId)
    }

    func markAllRead() {
        var updated = Array(notifications)
        var idsToClear: [String] = []
        var tabIdsToClearPanelUnread = panelDerivedUnreadWorkspaceIds
        for index in updated.indices {
            if !updated[index].isRead {
                tabIdsToClearPanelUnread.insert(updated[index].tabId)
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            replaceNotificationFeed(updated)
        }
        clearWorkspaceManualUnread()
        clearAllWorkspacePanelUnread(forTabIds: tabIdsToClearPanelUnread)
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        if !idsToClear.isEmpty {
            externalBannerOwnership.clearAll()
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
            emitNotificationsDismissed(
                ids: idsToClear,
                drainedSuperseded: supersededPhoneDismissBuffer.flushAll()
            )
        }
    }

    func remove(id: UUID) {
        var updated = Array(notifications)
        let removed = updated.first(where: { $0.id == id })
        let originalCount = updated.count
        updated.removeAll { $0.id == id }
        guard updated.count != originalCount else { return }
        let drainedSuperseded = removed.map(supersededPhoneDismissesForRowAction) ?? []
        replaceNotificationFeed(updated)
        externalBannerOwnership.clear(id: id)
        if let removed {
            clearFocusedReadIndicator(forTabId: removed.tabId, surfaceId: removed.surfaceId)
        }
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
        emitNotificationsDismissed(ids: [id.uuidString], drainedSuperseded: drainedSuperseded)
    }

    @discardableResult
    func removeReadNotifications() -> Int {
        var retained: [TerminalNotification] = []
        var removed: [TerminalNotification] = []
        retained.reserveCapacity(notifications.count)
        for notification in notifications {
            if notification.isRead {
                removed.append(notification)
            } else {
                retained.append(notification)
            }
        }
        guard !removed.isEmpty else { return 0 }
        var drainedSuperseded: [String] = []
        drainedSuperseded.reserveCapacity(removed.count)
        for notification in removed {
            drainedSuperseded.append(contentsOf: supersededPhoneDismissesForRowAction(notification))
        }
        replaceNotificationFeed(retained)
        let ids = removed.map { $0.id.uuidString }
        externalBannerOwnership.clear(ids: ids)
        for notification in removed {
            clearFocusedReadIndicator(forTabId: notification.tabId, surfaceId: notification.surfaceId)
        }
        center.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        emitNotificationsDismissed(ids: ids, drainedSuperseded: drainedSuperseded)
        return removed.count
    }

    private func supersededPhoneDismissesForRowAction(_ notification: TerminalNotification) -> [String] {
        guard externalBannerOwnership.owner(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId
        )?.id == notification.id else { return [] }
        let phoneKey = SupersededPhoneDismissBuffer.key(tabId: notification.tabId, surfaceId: notification.surfaceId)
        return supersededPhoneDismissBuffer.flush(forKey: phoneKey)
    }

    func externalBannerOwnerNotificationIDs(forTabId tabId: UUID) -> [UUID] {
        externalBannerOwnership.ownerIDs(tabId: tabId)
    }

    func applySessionNotificationMerge(
        _ merged: [TerminalNotification],
        restoredExternalBannerOwnerIDs: Set<UUID> = []
    ) {
        let existing = Array(notifications)
        guard merged != existing || !restoredExternalBannerOwnerIDs.isEmpty else { return }
        externalBannerOwnership.reconcile(
            previous: existing,
            merged: merged,
            restoredOwnerIDs: restoredExternalBannerOwnerIDs
        )
        if merged != existing { replaceNotificationFeed(merged) }
    }

    func transferSessionNotificationState(fromTabId: UUID, toTabId: UUID, panelIdMap: [UUID: UUID]) {
        inFlightPolicyRequests.transfer(
            fromTabId: fromTabId,
            toTabId: toTabId,
            panelIdMap: panelIdMap
        )
        let manual = Self.replacingWorkspaceId(in: manualUnreadWorkspaceIds, from: fromTabId, to: toTabId)
        if manual != manualUnreadWorkspaceIds { manualUnreadWorkspaceIds = manual }
        let panel = Self.replacingWorkspaceId(in: panelDerivedUnreadWorkspaceIds, from: fromTabId, to: toTabId)
        if panel != panelDerivedUnreadWorkspaceIds { panelDerivedUnreadWorkspaceIds = panel }
        let restored = Self.replacingWorkspaceId(in: restoredUnreadWorkspaceIds, from: fromTabId, to: toTabId)
        if restored != restoredUnreadWorkspaceIds { restoredUnreadWorkspaceIds = restored }
        var focused = focusedReadIndicatorByTabId
        if let oldSurfaceId = focused.removeValue(forKey: fromTabId), focused[toTabId] == nil {
            focused[toTabId] = panelIdMap[oldSurfaceId] ?? oldSurfaceId
        }
        if focused != focusedReadIndicatorByTabId { focusedReadIndicatorByTabId = focused }
        let sourceOwnersByID = Dictionary(
            uniqueKeysWithValues: externalBannerOwnership.owners(tabId: fromTabId).map { ($0.id, $0) }
        )
        let destinationOwnersByID = Dictionary(
            uniqueKeysWithValues: externalBannerOwnership.owners(tabId: toTabId).map { ($0.id, $0) }
        )
        let displacedOwners = externalBannerOwnership.transfer(
            fromTabId: fromTabId,
            toTabId: toTabId,
            panelIdMap: panelIdMap
        )
        let displacedOwnerIDs = Set(displacedOwners.map(\.id))
        let displacedSourceKeys = Set<String>(sourceOwnersByID.values.compactMap { owner in
            guard displacedOwnerIDs.contains(owner.id) else { return nil }
            return SupersededPhoneDismissBuffer.key(tabId: owner.tabId, surfaceId: owner.surfaceId)
        })
        let displacedDestinationKeys = Set<String>(destinationOwnersByID.values.compactMap { owner in
            guard displacedOwnerIDs.contains(owner.id) else { return nil }
            return SupersededPhoneDismissBuffer.key(tabId: owner.tabId, surfaceId: owner.surfaceId)
        })
        var displacedSuperseded = displacedDestinationKeys.sorted().flatMap {
            supersededPhoneDismissBuffer.flush(forKey: $0)
        }
        displacedSuperseded.append(contentsOf: supersededPhoneDismissBuffer.transfer(
            fromTabId: fromTabId,
            toTabId: toTabId,
            panelIdMap: panelIdMap,
            drainingSourceKeys: displacedSourceKeys
        ))
        dismissDisplacedExternalBannerOwners(displacedOwners, drainedSuperseded: displacedSuperseded)
    }

    private func dismissDisplacedExternalBannerOwners(
        _ displacedOwners: [TerminalNotification],
        drainedSuperseded: [String]
    ) {
        guard !displacedOwners.isEmpty else { return }
        let displacedIds = Set(displacedOwners.map { $0.id.uuidString }).sorted()
        center.removeDeliveredNotificationsOffMain(withIdentifiers: displacedIds)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: displacedIds)
        emitNotificationsDismissed(ids: displacedIds, drainedSuperseded: drainedSuperseded)
    }

    private func replaceNotificationsForClear(_ next: [TerminalNotification]) {
        suppressNotificationDiffPublishing = true
        replaceNotificationFeed(next)
        suppressNotificationDiffPublishing = false
    }

    func clearAll(
        discardQueuedNotifications: Bool = true,
        throughNotificationGeneration: UInt64? = nil
    ) {
        inFlightPolicyRequests.discardAll(through: throughNotificationGeneration)
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotifications() }
        guard !notifications.isEmpty ||
            !focusedReadIndicatorByTabId.isEmpty ||
            !manualUnreadWorkspaceIds.isEmpty ||
            !panelDerivedUnreadWorkspaceIds.isEmpty ||
            !restoredUnreadWorkspaceIds.isEmpty else { return }
        let tabIdsToClearPanelUnread = panelDerivedUnreadWorkspaceIds.union(notifications.map(\.tabId))
        let ids = notifications.map { $0.id.uuidString }
        replaceNotificationsForClear([])
        externalBannerOwnership.clearAll()
        clearWorkspaceManualUnread()
        clearAllWorkspacePanelUnread(forTabIds: tabIdsToClearPanelUnread)
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        focusedReadIndicatorByTabId.removeAll()
        CmuxEventBus.shared.publishNotificationCleared(ids: ids, workspaceId: nil, surfaceId: nil)
        center.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: ids)
        emitNotificationsDismissed(ids: ids, drainedSuperseded: supersededPhoneDismissBuffer.flushAll())
    }

    func clearNotifications(
        forTabId tabId: UUID,
        surfaceId: UUID?,
        discardQueuedNotifications: Bool = true,
        throughNotificationGeneration: UInt64? = nil
    ) {
        let liveTabId = surfaceId.flatMap {
            AppDelegate.shared?.agentNotificationDeliveryTarget(claimedTabId: tabId, surfaceId: $0)?.tabId
        } ?? tabId
        let tabIds = Set([tabId, liveTabId])
        inFlightPolicyRequests.discard(
            forTabId: tabId,
            surfaceId: surfaceId,
            through: throughNotificationGeneration
        )
        if discardQueuedNotifications {
            TerminalMutationBus.shared.discardPendingNotificationsForClear(
                tabId: liveTabId,
                surfaceId: surfaceId
            )
        }
        let hadRestoredWorkspaceUnread = surfaceId == nil && restoredUnreadWorkspaceIds.contains(tabId)
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        var indicatorTabIds: Set<UUID> = [tabId]
        var supersededDrained: [String] = []
        for notification in notifications {
            if notification.matchesClear(tabId: tabId, liveTabId: liveTabId, surfaceId: surfaceId) {
                idsToClear.append(notification.id.uuidString)
                indicatorTabIds.insert(notification.tabId)
                supersededDrained.append(contentsOf: supersededPhoneDismissBuffer.flush(
                    forKey: SupersededPhoneDismissBuffer.key(
                        tabId: notification.tabId,
                        surfaceId: notification.surfaceId
                    )
                ))
            } else {
                updated.append(notification)
            }
        }
        let hadFocusedReadIndicator = indicatorTabIds.contains {
            focusedReadIndicatorByTabId[$0].map { $0 == surfaceId } ?? false
        }
        guard !idsToClear.isEmpty || hadFocusedReadIndicator || hadRestoredWorkspaceUnread else { return }
        if !idsToClear.isEmpty {
            replaceNotificationsForClear(updated)
        }
        if surfaceId == nil {
            setWorkspaceRestoredUnread(false, forTabId: tabId)
        }
        indicatorTabIds.forEach { clearFocusedReadIndicator(forTabId: $0, surfaceId: surfaceId) }
        if !idsToClear.isEmpty {
            externalBannerOwnership.clear(ids: idsToClear)
            CmuxEventBus.shared.publishNotificationCleared(
                ids: idsToClear,
                workspaceId: tabIds.count == 1 ? tabId : nil,
                surfaceId: surfaceId
            )
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
            emitNotificationsDismissed(ids: idsToClear, drainedSuperseded: supersededDrained)
        }
    }

    func rebindSurfaceNotifications(fromTabId sourceTabId: UUID, toTabId destinationTabId: UUID, surfaceId: UUID) {
        guard sourceTabId != destinationTabId else { return }
        TerminalMutationBus.shared.rebindPendingNotifications(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            surfaceId: surfaceId
        )
        inFlightPolicyRequests.rebindSurface(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            surfaceId: surfaceId
        )

        var didMoveNotification = false
        let hasUnreadSourceConfinedNotification = notifications.contains {
            !$0.isRead &&
                !$0.retargetsToLiveSurfaceOwner &&
                $0.matches(tabId: sourceTabId, surfaceId: surfaceId)
        }
        let updated = notifications.map { notification -> TerminalNotification in
            guard notification.retargetsToLiveSurfaceOwner,
                  notification.matches(tabId: sourceTabId, surfaceId: surfaceId) else {
                return notification
            }
            didMoveNotification = true
            return notification.replacingLocation(
                tabId: destinationTabId,
                surfaceId: notification.surfaceId,
                panelId: notification.panelId
            )
        }
        if didMoveNotification {
            let bannerOwnerRetargets = externalBannerOwnership.owner(
                tabId: sourceTabId,
                surfaceId: surfaceId
            )?.retargetsToLiveSurfaceOwner == true
            let sourceOwner = externalBannerOwnership.owner(tabId: sourceTabId, surfaceId: surfaceId)
            let destinationOwner = externalBannerOwnership.owner(tabId: destinationTabId, surfaceId: surfaceId)
            let displacedOwner: TerminalNotification?
            if bannerOwnerRetargets {
                displacedOwner = externalBannerOwnership.rebind(
                    surfaceId: surfaceId,
                    fromTabId: sourceTabId,
                    toTabId: destinationTabId
                )
                let displacedOwnerId = displacedOwner?.id
                let sourceWasDisplaced = displacedOwnerId == sourceOwner?.id
                let destinationWasDisplaced = displacedOwnerId == destinationOwner?.id
                var displacedSuperseded: [String] = []
                if destinationWasDisplaced {
                    displacedSuperseded.append(contentsOf: supersededPhoneDismissBuffer.flush(
                        forKey: SupersededPhoneDismissBuffer.key(tabId: destinationTabId, surfaceId: surfaceId)
                    ))
                }
                displacedSuperseded.append(contentsOf: supersededPhoneDismissBuffer.rebind(
                    surfaceId: surfaceId,
                    fromTabId: sourceTabId,
                    toTabId: destinationTabId,
                    drainSource: sourceWasDisplaced
                ))
                dismissDisplacedExternalBannerOwners(
                    displacedOwner.map { [$0] } ?? [],
                    drainedSuperseded: displacedSuperseded
                )
            } else {
                displacedOwner = nil
            }
            replaceNotificationFeed(updated)
        }

        if !hasUnreadSourceConfinedNotification,
           focusedReadIndicatorByTabId[sourceTabId] == surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: sourceTabId)
            if focusedReadIndicatorByTabId[destinationTabId] == nil {
                focusedReadIndicatorByTabId[destinationTabId] = surfaceId
            }
        }
    }

    func clearNotifications(
        forTabId tabId: UUID,
        discardQueuedNotifications: Bool = true,
        throughNotificationGeneration: UInt64? = nil
    ) {
        inFlightPolicyRequests.discard(
            forTabId: tabId,
            surfaceId: nil,
            through: throughNotificationGeneration
        )
        if discardQueuedNotifications {
            TerminalMutationBus.shared.discardPendingNotificationsForClear(tabId: tabId, surfaceId: nil)
        }
        let hadFocusedReadIndicator = focusedReadIndicatorByTabId[tabId] != nil
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        setWorkspaceManualUnread(false, forTabId: tabId)
        clearWorkspacePanelUnread(forTabId: tabId)
        setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
        guard !idsToClear.isEmpty || hadFocusedReadIndicator else { return }
        if !idsToClear.isEmpty {
            replaceNotificationsForClear(updated)
        }
        clearFocusedReadIndicator(forTabId: tabId)
        if !idsToClear.isEmpty {
            externalBannerOwnership.clear(tabId: tabId)
            CmuxEventBus.shared.publishNotificationCleared(ids: idsToClear, workspaceId: tabId, surfaceId: nil)
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
            emitNotificationsDismissed(
                ids: idsToClear,
                drainedSuperseded: supersededPhoneDismissBuffer.flush(matchingTabId: tabId)
            )
        }
    }

    /// `completion` receives the decision plus the effective authorization
    /// state behind it. The state matters for the just-prompted-and-declined
    /// case: `authorizationState` is refreshed asynchronously there, so a
    /// caller reading the property would still see `.notDetermined` and play
    /// the fallback sound for the very notification whose prompt the user
    /// just denied.
    func ensureAuthorization(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool, NotificationAuthorizationState) -> Void
    ) {
        if origin == .notificationDelivery,
           let cachedDecision = Self.cachedDeliveryAuthorizationDecision(
               for: authorizationState,
               isAppActive: AppFocusState.isAppActive()
           ) {
            if !cachedDecision, authorizationState == .notDetermined {
                hasDeferredAuthorizationRequest = true
            }
            completion(cachedDecision, authorizationState)
            return
        }

        logAuthorization("ensure start origin=\(origin.rawValue)")
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false, .unknown)
                    return
                }

                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "ensure status origin=\(origin.rawValue) status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel) appActive=\(AppFocusState.isAppActive())"
                )
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(true, self.authorizationState)
                case .denied:
                    if origin != .notificationDelivery {
                        self.logAuthorization("ensure denied origin=\(origin.rawValue) prompting_settings")
                        self.promptToEnableNotifications()
                    }
                    completion(false, .denied)
                case .notDetermined:
                    if Self.shouldDeferAutomaticAuthorizationRequest(
                        origin: origin,
                        status: settings.authorizationStatus,
                        isAppActive: AppFocusState.isAppActive()
                    ) {
                        self.logAuthorization("ensure deferred origin=\(origin.rawValue)")
                        self.hasDeferredAuthorizationRequest = true
                        completion(false, .notDetermined)
                    } else {
                        self.requestAuthorizationIfNeeded(origin: origin, completion)
                    }
                @unknown default:
                    self.logAuthorization("ensure unknown status origin=\(origin.rawValue)")
                    completion(false, .unknown)
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool, NotificationAuthorizationState) -> Void
    ) {
        let isAutomaticRequest = origin == .notificationDelivery
        guard Self.shouldRequestAuthorization(
            isAutomaticRequest: isAutomaticRequest,
            hasRequestedAutomaticAuthorization: hasRequestedAutomaticAuthorization
        ) else {
            logAuthorization(
                "request blocked origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
            )
            completion(false, authorizationState)
            return
        }
        if isAutomaticRequest {
            hasRequestedAutomaticAuthorization = true
        }
        hasDeferredAuthorizationRequest = false
        logAuthorization(
            "request starting origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
        )
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    self.authorizationState = .authorized
                } else {
                    self.refreshAuthorizationStatus()
                }
                self.logAuthorization(
                    "request callback origin=\(origin.rawValue) granted=\(granted) error=\(error?.localizedDescription ?? "nil") mapped=\(self.authorizationState.statusLabel)"
                )
                // A non-grant without an error is the user answering the
                // prompt with a live denial, even while authorizationState is
                // still refreshing. A request error is not a user decision,
                // so it reports .unknown and the fallback sound stays on
                // (fail-open).
                let effectiveState: NotificationAuthorizationState =
                    granted ? .authorized : (error == nil ? .denied : .unknown)
                completion(granted, effectiveState)
            }
        }
    }

    private func promptToEnableNotifications() {
        guard !hasPromptedForSettings else { return }
        logAuthorization("prompt settings shown")
        hasPromptedForSettings = true
        presentNotificationSettingsPrompt(attempt: 0)
    }

    private func presentNotificationSettingsPrompt(attempt: Int) {
        guard let window = notificationSettingsWindowProvider() else {
            guard attempt < settingsPromptWindowRetryLimit else {
                // If no window is available after retries, allow a future denied callback
                // to prompt again when the app has a key/main window.
                hasPromptedForSettings = false
                return
            }
            notificationSettingsScheduler(settingsPromptWindowRetryDelay) { [weak self] in
                self?.presentNotificationSettingsPrompt(attempt: attempt + 1)
            }
            return
        }

        let alert = notificationSettingsAlertFactory()
        alert.messageText = String(localized: "dialog.enableNotifications.title", defaultValue: "Enable Notifications for cmux")
        alert.informativeText = String(localized: "dialog.enableNotifications.message", defaultValue: "Notifications are disabled for cmux. Enable them in System Settings to see alerts.")
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.openSettings", defaultValue: "Open Settings"))
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.notNow", defaultValue: "Not Now"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.openNotificationSettings()
        }
    }

    static func authorizationState(from status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    static func shouldDeferAutomaticAuthorizationRequest(
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        status == .notDetermined && !isAppActive
    }

    static func shouldRequestAuthorization(
        isAutomaticRequest: Bool,
        hasRequestedAutomaticAuthorization: Bool
    ) -> Bool {
        guard isAutomaticRequest else { return true }
        return !hasRequestedAutomaticAuthorization
    }

    private static func shouldDeferAutomaticAuthorizationRequest(
        origin: AuthorizationRequestOrigin,
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        guard origin == .notificationDelivery else { return false }
        return shouldDeferAutomaticAuthorizationRequest(status: status, isAppActive: isAppActive)
    }

#if DEBUG
    func configureNotificationSettingsPromptHooksForTesting(
        windowProvider: @escaping () -> NSWindow?,
        alertFactory: @escaping () -> NSAlert,
        scheduler: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void,
        urlOpener: @escaping (URL) -> Void
    ) {
        notificationSettingsWindowProvider = windowProvider
        notificationSettingsAlertFactory = alertFactory
        notificationSettingsScheduler = scheduler
        notificationSettingsURLOpener = urlOpener
        hasPromptedForSettings = false
    }

    func resetNotificationSettingsPromptHooksForTesting() {
        notificationSettingsWindowProvider = { NSApp.keyWindow ?? NSApp.mainWindow }
        notificationSettingsAlertFactory = { NSAlert() }
        notificationSettingsScheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                block()
            }
        }
        notificationSettingsURLOpener = { url in NSWorkspace.shared.open(url) }
        hasPromptedForSettings = false
    }

    func configureNotificationDeliveryHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        notificationDeliveryHandler = { store, notification, _ in
            handler(store, notification)
        }
    }

    func configureNotificationDeliveryHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void
    ) {
        notificationDeliveryHandler = handler
    }

    func resetNotificationDeliveryHandlerForTesting() {
        notificationDeliveryHandler = { store, notification, effects in
            store.scheduleUserNotification(notification, effects: effects)
        }
    }

    func configureNativeNotificationDeliveryHooksForTesting(
        _ update: (inout NativeNotificationDeliveryHooks) -> Void
    ) {
        update(&nativeNotificationDeliveryHooks)
    }

    func configureSuppressedNotificationFeedbackHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        suppressedNotificationFeedbackHandler = { store, notification, _ in
            handler(store, notification)
        }
    }

    func configureSuppressedNotificationFeedbackHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void
    ) {
        suppressedNotificationFeedbackHandler = handler
    }

    func resetSuppressedNotificationFeedbackHandlerForTesting() {
        suppressedNotificationFeedbackHandler = { store, notification, effects in
            store.playSuppressedNotificationFeedback(for: notification, effects: effects)
        }
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting<S: Sequence>(_ notificationSequence: S)
    where S.Element == TerminalNotification {
        let notifications = Array(notificationSequence)
        TerminalMutationBus.shared.discardPendingNotifications()
        deferredUnreadNavigationIds.removeAll()
        replaceNotificationFeed(notifications)
        externalBannerOwnership.resetAssumingOwners(from: Array(self.notifications))
        clearWorkspaceManualUnread()
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        focusedReadIndicatorByTabId.removeAll()
    }

    func stashSupersededPhoneDismissIDsForTesting(_ ids: [String], tabId: UUID, surfaceId: UUID?) {
        supersededPhoneDismissBuffer.stash(
            ids: ids,
            forKey: SupersededPhoneDismissBuffer.key(tabId: tabId, surfaceId: surfaceId)
        )
    }

    func flushSupersededPhoneDismissIDsForTesting(tabId: UUID, surfaceId: UUID?) -> [String] {
        supersededPhoneDismissBuffer.flush(
            forKey: SupersededPhoneDismissBuffer.key(tabId: tabId, surfaceId: surfaceId)
        )
    }

    func externalBannerOwnerIDForTesting(tabId: UUID, surfaceId: UUID?) -> UUID? {
        externalBannerOwnership.owner(tabId: tabId, surfaceId: surfaceId)?.id
    }

#endif

    private func refreshDockBadge() {
        let label = Self.dockBadgeLabel(
            unreadCount: unreadCount,
            isEnabled: NotificationBadgeSettings.isDockBadgeEnabled(),
            runTag: TaggedRunBadgeSettings.normalizedTag()
        )
        NSApp?.dockTile.badgeLabel = label
    }
}

/// Immutable per-workspace unread projection rendered by the sidebar. Equatable
/// so the coalesced model only republishes when a workspace's badge or
/// latest-message text actually changes. `latestNotificationText` is the
/// trimmed body-or-title of the latest notification (read or unread) and is NOT
/// gated by the `showsSidebarNotificationMessage` setting; the sidebar applies
/// that gate at its read site.
struct SidebarWorkspaceUnreadSummary: Equatable {
    var unreadCount: Int
    var latestNotificationText: String?
}

/// Workspace + surface pair used to mirror the store's per-surface unread set.
struct SidebarSurfaceUnreadKey: Hashable {
    var workspaceId: UUID
    var surfaceId: UUID?
}

/// Lightweight observable that the workspace sidebar and `ContentView` observe
/// instead of `TerminalNotificationStore`. `TerminalNotificationStore` drives it
/// from its single `refreshUnreadPresentation()` coalescing hub with equality
/// guards, so notification activity that does not change any workspace's badge,
/// latest-text, per-surface unread, or read-indicator never fires
/// `objectWillChange` here. That is what stops high-frequency notification churn
/// from re-rendering the workspace list (issue #2586 class of sidebar re-render
/// spins). The query methods mirror the equivalent `TerminalNotificationStore`
/// reads exactly so callers can switch source without behavior change.
@MainActor
final class SidebarUnreadModel: ObservableObject {
    @Published private(set) var totalUnreadCount: Int = 0
    @Published private(set) var summaryByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary] = [:]
    @Published private(set) var unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey> = []
    @Published private(set) var focusedReadIndicatorByWorkspaceId: [UUID: UUID] = [:]
    @Published private(set) var manualUnreadWorkspaceIds: Set<UUID> = []

    func apply(
        totalUnreadCount: Int,
        summaries: [UUID: SidebarWorkspaceUnreadSummary],
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        focusedReadIndicatorByWorkspaceId: [UUID: UUID],
        manualUnreadWorkspaceIds: Set<UUID>
    ) {
        if self.totalUnreadCount != totalUnreadCount {
            self.totalUnreadCount = totalUnreadCount
        }
        if summaryByWorkspaceId != summaries {
            summaryByWorkspaceId = summaries
        }
        if self.unreadSurfaceKeys != unreadSurfaceKeys {
            self.unreadSurfaceKeys = unreadSurfaceKeys
        }
        if self.focusedReadIndicatorByWorkspaceId != focusedReadIndicatorByWorkspaceId {
            self.focusedReadIndicatorByWorkspaceId = focusedReadIndicatorByWorkspaceId
        }
        if self.manualUnreadWorkspaceIds != manualUnreadWorkspaceIds {
            self.manualUnreadWorkspaceIds = manualUnreadWorkspaceIds
        }
    }

    func applyIncremental(
        totalUnreadCount: Int,
        changedSummaries: [UUID: SidebarWorkspaceUnreadSummary],
        removedSummaryIds: Set<UUID>,
        insertedUnreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        removedUnreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        focusedReadIndicatorByWorkspaceId: [UUID: UUID],
        manualUnreadWorkspaceIds: Set<UUID>
    ) {
        if self.totalUnreadCount != totalUnreadCount {
            self.totalUnreadCount = totalUnreadCount
        }
        var nextSummaries = summaryByWorkspaceId
        for id in removedSummaryIds where nextSummaries[id] != nil {
            nextSummaries.removeValue(forKey: id)
        }
        for (id, summary) in changedSummaries where nextSummaries[id] != summary {
            nextSummaries[id] = summary
        }
        if summaryByWorkspaceId != nextSummaries {
            summaryByWorkspaceId = nextSummaries
        }
        var nextSurfaceKeys = unreadSurfaceKeys
        for key in removedUnreadSurfaceKeys {
            nextSurfaceKeys.remove(key)
        }
        for key in insertedUnreadSurfaceKeys {
            nextSurfaceKeys.insert(key)
        }
        if unreadSurfaceKeys != nextSurfaceKeys {
            unreadSurfaceKeys = nextSurfaceKeys
        }
        if self.focusedReadIndicatorByWorkspaceId != focusedReadIndicatorByWorkspaceId {
            self.focusedReadIndicatorByWorkspaceId = focusedReadIndicatorByWorkspaceId
        }
        if self.manualUnreadWorkspaceIds != manualUnreadWorkspaceIds {
            self.manualUnreadWorkspaceIds = manualUnreadWorkspaceIds
        }
    }

    func summary(forWorkspaceId id: UUID) -> SidebarWorkspaceUnreadSummary {
        summaryByWorkspaceId[id] ?? SidebarWorkspaceUnreadSummary(unreadCount: 0, latestNotificationText: nil)
    }

    func unreadCount(forWorkspaceId id: UUID) -> Int {
        summary(forWorkspaceId: id).unreadCount
    }

    func latestNotificationText(forWorkspaceId id: UUID) -> String? {
        summary(forWorkspaceId: id).latestNotificationText
    }

    func workspaceIsUnread(forWorkspaceId id: UUID) -> Bool {
        unreadCount(forWorkspaceId: id) > 0
    }

    func hasManualUnread(forWorkspaceId id: UUID) -> Bool {
        manualUnreadWorkspaceIds.contains(id)
    }

    func hasUnreadNotification(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        unreadSurfaceKeys.contains(SidebarSurfaceUnreadKey(workspaceId: id, surfaceId: surfaceId))
    }

    func hasVisibleNotificationIndicator(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forWorkspaceId: id, surfaceId: surfaceId) ||
            (focusedReadIndicatorByWorkspaceId[id].map { $0 == surfaceId } ?? false)
    }

    func canMarkWorkspaceRead(forWorkspaceIds ids: [UUID]) -> Bool {
        ids.contains { workspaceIsUnread(forWorkspaceId: $0) }
    }

    func canMarkWorkspaceUnread(forWorkspaceIds ids: [UUID]) -> Bool {
        ids.contains { !workspaceIsUnread(forWorkspaceId: $0) }
    }
}
