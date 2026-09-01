import CmuxFoundation
import CmuxNotifications
import AppKit
import Combine
import Foundation
import os
import UserNotifications
import Bonsplit
import CmuxSettings
import CmuxNotifications

nonisolated private let terminalNotificationLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification"
)

extension TerminalNotificationStore {
    nonisolated static func shouldAttemptPhoneForward(
        effects _: TerminalNotificationPolicyEffects,
        phoneForwardingEnabled: Bool,
        categoryAllowsDelivery: Bool
    ) -> Bool {
        phoneForwardingEnabled && categoryAllowsDelivery
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
    private struct TabSurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    private struct NotificationIndexes {
        var unreadCount = 0
        var unreadCountByTabId: [UUID: Int] = [:]
        var unreadByTabSurface = Set<TabSurfaceKey>()
        var latestUnreadByTabId: [UUID: TerminalNotification] = [:]
        var latestByTabId: [UUID: TerminalNotification] = [:]
    }

    static let shared = TerminalNotificationStore(
        userNotificationCenter: UserNotificationCenterService(
            center: UNUserNotificationCenter.current()
        )
    )
    let notificationHookCache = CmuxNotificationHookCache()

    static let authorizationStatusDidChangeNotification = Notification.Name("cmux.terminalNotificationAuthorizationStatusDidChange")
    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let textReplyCategoryIdentifier = "com.cmuxterm.app.userNotification.textReply"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"
    static let actionReplyIdentifier = "terminal.reply"
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

    /// Invalidates the paired phone's notification feed without sending any
    /// notification content in the event frame. The phone fetches the
    /// authoritative snapshot through `notification.feed.list`.
    static let feedChangedEventTopic = "notification.feed.changed"

    /// Durable chronological history for the paired-phone notification feed.
    private(set) var notificationFeedHistory: NotificationFeedHistoryStore

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

    /// Drop the in-memory tombstone copy so the next use re-reads the persisted
    /// ring — the behavior-test analogue of a process restart.
    func reloadDismissedTombstonesForTesting() {
        dismissedTombstoneIDs.removeAll()
        dismissedTombstoneOrder.removeAll()
        dismissedTombstonesLoaded = false
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

    /// Classify which of the phone's delivered banner ids have been handled on
    /// this Mac: still in the store and read, or recently removed (tombstoned).
    /// Ids this Mac has never seen are NOT reported handled — they may belong to
    /// a different paired Mac — so the phone leaves those banners alone. An id
    /// that is currently unread is never handled, even if an older tombstone
    /// exists (markUnread after a dismiss resurrects it).
    func reconcileHandledNotificationIDs(deliveredIDs: [UUID]) -> [String] {
        guard !deliveredIDs.isEmpty else { return [] }
        loadDismissedTombstonesIfNeeded()
        var readIDs = Set<UUID>()
        var knownIDs = Set<UUID>()
        for notification in notifications {
            knownIDs.insert(notification.id)
            if notification.isRead { readIDs.insert(notification.id) }
        }
        return deliveredIDs
            .filter { id in
                if knownIDs.contains(id) { return readIDs.contains(id) }
                return dismissedTombstoneIDs.contains(id)
            }
            .map(\.uuidString)
    }

    /// Forwards a dismiss/clear to the user's phone. Call only from the
    /// change-confirmed branch of a user-driven read/clear/remove path, so the
    /// Mac→iOS→Mac echo can't loop. Session restore / surface rebind paths must
    /// NOT call this: they reassign ids on churn and would clear a phone banner
    /// that should persist.
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

    private enum AuthorizationRequestOrigin: String {
        case notificationDelivery = "notification_delivery"
        case settingsButton = "settings_button"
        case settingsTest = "settings_test"
    }

    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
            indexes = Self.buildIndexes(for: notifications)
            refreshUnreadPresentation()
            if !suppressNotificationDiffPublishing { CmuxEventBus.shared.publishNotificationChanges(oldValue: oldValue, newValue: notifications) }
        }
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
    // Workspace panels own their manual unread state on Workspace. Dock panels
    // have no Workspace owner, so their surface-scoped state lives here beside
    // the cross-container unread projection.
    private(set) var manualUnreadWorkspaceIds: Set<UUID> = []
    /// Surface-scoped manual unread belongs only to per-window Docks. Keep the
    /// owner index and the published sidebar projection in lockstep so BEL
    /// handling stays constant-time and refreshes once per logical mutation.
    private var manualUnreadSurfaceIdsByOwnerId: [UUID: Set<UUID>] = [:]
    private var manualUnreadSurfaceKeys: Set<SidebarSurfaceUnreadKey> = []
    private var manualUnreadSurfaceTargetsByRecency: [WindowDockUnreadTarget] = []
    private(set) var panelDerivedUnreadWorkspaceIds: Set<UUID> = []
    private(set) var restoredUnreadWorkspaceIds: Set<UUID> = []
    @Published private(set) var focusedReadIndicatorByTabId: [UUID: UUID] = [:] {
        didSet {
            // The sidebar/pane read-indicator presentation derives from this map
            // (see hasVisibleNotificationIndicator); keep the coalesced
            // SidebarUnreadModel in sync when it changes on its own.
            guard focusedReadIndicatorByTabId != oldValue else { return }
            refreshUnreadPresentation()
        }
    }
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown {
        didSet {
            guard authorizationState != oldValue else { return }
            NotificationCenter.default.post(
                name: Self.authorizationStatusDidChangeNotification,
                object: nil
            )
        }
    }
    private var suppressNotificationDiffPublishing = false

    let userNotificationCenter: UserNotificationCenterService
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
    private var nativeNotificationDeliveryHooks: NativeNotificationDeliveryHooks
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
    var lastNotificationHookFailureDateByKey: [NotificationHookFailureThrottleKey: Date] = [:]
    private var indexes = NotificationIndexes()
    private let inFlightPolicyRequests = TerminalNotificationPolicyInFlightStore()
    private init(userNotificationCenter: UserNotificationCenterService) {
        self.userNotificationCenter = userNotificationCenter
        nativeNotificationDeliveryHooks = NativeNotificationDeliveryHooks(
            userNotificationCenter: userNotificationCenter
        )
        notificationFeedHistory = NotificationFeedHistoryStore(
            fileURL: NotificationFeedHistoryStore.defaultFileURL()
        ) { revision in
            MobileHostService.emitEvent(
                topic: Self.feedChangedEventTopic,
                payload: ["revision": revision]
            )
        }
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

    private func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        Task { [userNotificationCenter] in
            _ = await userNotificationCenter.removeDeliveredNotifications(
                withIdentifiers: identifiers
            )
        }
    }

    private func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        Task { [userNotificationCenter] in
            _ = await userNotificationCenter.removePendingNotificationRequests(
                withIdentifiers: identifiers
            )
        }
    }

    static func dockBadgeLabel(unreadCount: Int, isEnabled: Bool, runTag: String? = nil) -> String? {
        let unreadLabel: String? = {
            guard isEnabled, unreadCount > 0 else { return nil }
            if unreadCount > 99 {
                return "99+"
            }
            return String(unreadCount)
        }()

        if let tag = TaggedRunBadgeSettings.normalizedTag(runTag) {
            if let unreadLabel {
                return "\(tag):\(unreadLabel)"
            }
            return tag
        }

        return unreadLabel
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
        workspaceUnreadIndicatorIds.count + manualUnreadSurfaceIdsByOwnerId.count
    }

    var windowDockUnreadTargets: [WindowDockUnreadTarget] {
        Array(manualUnreadSurfaceTargetsByRecency.reversed())
    }

    private func refreshUnreadPresentation() {
        let nextMenuSnapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notifications,
            workspaceUnreadIndicatorCount: workspaceUnreadIndicatorCount
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
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIds,
            manualUnreadSurfaceIdsByOwnerId: manualUnreadSurfaceIdsByOwnerId
        )
        refreshDockBadge()
        emitUnreadBadgeEventIfChanged()
    }

    /// Publishes one per-window Dock surface mutation without rebuilding the
    /// notification-derived summaries and surface index. Window-Dock owner ids
    /// are not workspace rows, so only the surface key and global owner count can
    /// change here.
    private func refreshSurfaceManualUnreadPresentation(
        for key: SidebarSurfaceUnreadKey,
        ownerUnreadChanged: Bool
    ) {
        let remainsUnreadFromNotification = indexes.unreadByTabSurface.contains(
            TabSurfaceKey(tabId: key.workspaceId, surfaceId: key.surfaceId)
        )
        sidebarUnread.applySurfaceUnreadProjection(
            key,
            isUnread: manualUnreadSurfaceKeys.contains(key) || remainsUnreadFromNotification,
            totalUnreadCount: unreadCount
        )
        guard ownerUnreadChanged else { return }

        refreshUnreadIndicatorTotals()
    }

    /// Publishes a workspace panel-indicator transition without rebuilding the
    /// surface index or unrelated workspace summaries.
    private func refreshWorkspacePanelUnreadPresentation(forTabId tabId: UUID) {
        sidebarUnread.applyWorkspaceSummaryProjection(
            forWorkspaceId: tabId,
            summary: buildSidebarUnreadSummary(forTabId: tabId),
            totalUnreadCount: unreadCount
        )
        refreshUnreadIndicatorTotals()
    }

    /// Refreshes global indicator totals after an incremental owner transition.
    private func refreshUnreadIndicatorTotals() {
        let nextMenuSnapshot = NotificationMenuSnapshot(
            unreadCount: unreadCount,
            hasNotifications: !notifications.isEmpty || workspaceUnreadIndicatorCount > 0,
            recentNotifications: notificationMenuSnapshot.recentNotifications
        )
        if notificationMenuSnapshot != nextMenuSnapshot {
            notificationMenuSnapshot = nextMenuSnapshot
        }
        refreshDockBadge()
        emitUnreadBadgeEventIfChanged()
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
            guard let summary = buildSidebarUnreadSummary(forTabId: id) else { continue }
            result[id] = summary
        }
        return result
    }

    /// Builds one workspace summary, omitting the default empty value.
    private func buildSidebarUnreadSummary(
        forTabId tabId: UUID
    ) -> SidebarWorkspaceUnreadSummary? {
        let count = unreadCount(forTabId: tabId)
        let latestNotification = indexes.latestByTabId[tabId]
        let latestText: String? = latestNotification.flatMap { notification in
            let text = notification.body.isEmpty ? notification.title : notification.body
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard count > 0 || latestNotification != nil else { return nil }
        return SidebarWorkspaceUnreadSummary(
            unreadCount: count,
            latestNotificationText: latestText,
            latestNotificationId: latestNotification?.id,
            latestNotificationCreatedAt: latestNotification?.createdAt,
            hasLatestNotification: latestNotification != nil
        )
    }

    private func logAuthorization(_ message: String) {
#if DEBUG
        cmuxDebugLog("notification.auth \(message)")
#endif
        terminalNotificationLogger.info("Authorization \(message, privacy: .private)")
    }

    private static func authorizationStatusLabel(
        _ status: UserNotificationAuthorizationStatus
    ) -> String {
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
        case .unknown(let rawValue):
            return "unknown(\(rawValue))"
        }
    }

    func refreshAuthorizationStatus() {
        Task { @MainActor [weak self, userNotificationCenter] in
            let result = await userNotificationCenter.authorizationStatus()
            guard let self else { return }
            switch result {
            case .success(let status):
                authorizationState = Self.authorizationState(from: status)
                logAuthorization(
                    "refresh status=\(Self.authorizationStatusLabel(status)) mapped=\(authorizationState.statusLabel)"
                )
            case .failure(let error):
                authorizationState = .unknown
                logAuthorization("refresh failed error=\(String(describing: error))")
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

            Task { @MainActor [weak self, userNotificationCenter] in
                let result = await userNotificationCenter.add(request)
                guard let self else { return }
                switch result {
                case .failure(let error):
                    terminalNotificationLogger.error(
                        "Failed to schedule test notification error=\(String(describing: error), privacy: .private)"
                    )
                    logAuthorization("settings test schedule failed error=\(String(describing: error))")
                    NotificationSoundSettings.playSelectedSound()
                case .success:
                    logAuthorization("settings test schedule succeeded")
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
        guard mutateWorkspaceManualUnread(isUnread, forTabId: tabId) else { return false }
        refreshUnreadPresentation()
        return true
    }

    /// Mutates workspace manual-unread state without publishing an intermediate projection.
    @discardableResult
    private func mutateWorkspaceManualUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        if isUnread {
            return manualUnreadWorkspaceIds.insert(tabId).inserted
        }
        return manualUnreadWorkspaceIds.remove(tabId) != nil
    }

    private func clearWorkspaceManualUnread() {
        guard !manualUnreadWorkspaceIds.isEmpty else { return }
        manualUnreadWorkspaceIds = []
        refreshUnreadPresentation()
    }

    @discardableResult
    private func setSurfaceManualUnread(
        _ isUnread: Bool,
        forTabId tabId: UUID,
        surfaceId: UUID
    ) -> Bool {
        let ownerWasUnread = manualUnreadSurfaceIdsByOwnerId[tabId]?.isEmpty == false
        guard mutateSurfaceManualUnread(
            isUnread,
            forTabId: tabId,
            surfaceId: surfaceId
        ) else {
            return false
        }
        let ownerIsUnread = manualUnreadSurfaceIdsByOwnerId[tabId]?.isEmpty == false
        refreshSurfaceManualUnreadPresentation(
            for: SidebarSurfaceUnreadKey(workspaceId: tabId, surfaceId: surfaceId),
            ownerUnreadChanged: ownerWasUnread != ownerIsUnread
        )
        return true
    }

    /// Mutates both Dock unread indexes without publishing intermediate projections.
    @discardableResult
    private func mutateSurfaceManualUnread(
        _ isUnread: Bool,
        forTabId tabId: UUID,
        surfaceId: UUID
    ) -> Bool {
        mutateSurfaceManualUnread(
            isUnread,
            for: CollectionOfOne(
                SidebarSurfaceUnreadKey(
                    workspaceId: tabId,
                    surfaceId: surfaceId
                )
            )
        )
    }

    /// Mutates both Dock unread indexes as one batch and filters recency once.
    @discardableResult
    private func mutateSurfaceManualUnread<Keys: Sequence>(
        _ isUnread: Bool,
        for keys: Keys
    ) -> Bool where Keys.Element == SidebarSurfaceUnreadKey {
        var didChange = false
        var removedTargets = Set<WindowDockUnreadTarget>()
        for key in keys {
            guard let surfaceId = key.surfaceId else { continue }
            var surfaceIds = manualUnreadSurfaceIdsByOwnerId[key.workspaceId] ?? []
            let keyDidChange = isUnread
                ? surfaceIds.insert(surfaceId).inserted
                : surfaceIds.remove(surfaceId) != nil
            guard keyDidChange else { continue }
            didChange = true
            if surfaceIds.isEmpty {
                manualUnreadSurfaceIdsByOwnerId.removeValue(forKey: key.workspaceId)
            } else {
                manualUnreadSurfaceIdsByOwnerId[key.workspaceId] = surfaceIds
            }
            let target = WindowDockUnreadTarget(
                windowId: key.workspaceId,
                surfaceId: surfaceId
            )
            if isUnread {
                manualUnreadSurfaceKeys.insert(key)
                manualUnreadSurfaceTargetsByRecency.append(target)
            } else {
                manualUnreadSurfaceKeys.remove(key)
                removedTargets.insert(target)
            }
        }
        if !removedTargets.isEmpty {
            manualUnreadSurfaceTargetsByRecency.removeAll {
                removedTargets.contains($0)
            }
        }
        return didChange
    }

    private func clearSurfaceManualUnread(
        for keys: Set<SidebarSurfaceUnreadKey>
    ) {
        if mutateSurfaceManualUnread(false, for: keys) {
            refreshUnreadPresentation()
        }
    }

    private func clearSurfaceManualUnread() {
        guard !manualUnreadSurfaceIdsByOwnerId.isEmpty else { return }
        manualUnreadSurfaceIdsByOwnerId.removeAll()
        manualUnreadSurfaceKeys.removeAll()
        manualUnreadSurfaceTargetsByRecency.removeAll()
        refreshUnreadPresentation()
    }

    @discardableResult
    private func clearSurfaceManualUnread(forTabId tabId: UUID) -> Bool {
        guard let surfaceIds = manualUnreadSurfaceIdsByOwnerId.removeValue(
            forKey: tabId
        ) else {
            return false
        }
        for surfaceId in surfaceIds {
            manualUnreadSurfaceKeys.remove(SidebarSurfaceUnreadKey(
                workspaceId: tabId,
                surfaceId: surfaceId
            ))
        }
        manualUnreadSurfaceTargetsByRecency.removeAll { $0.windowId == tabId }
        refreshUnreadPresentation()
        return true
    }

    @discardableResult
    private func setPanelDerivedWorkspaceUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        guard panelDerivedUnreadWorkspaceIds.contains(tabId) != isUnread else {
            return false
        }
        let ownerWasUnread = workspaceUnreadIndicatorIds.contains(tabId)
        if isUnread {
            panelDerivedUnreadWorkspaceIds.insert(tabId)
        } else {
            panelDerivedUnreadWorkspaceIds.remove(tabId)
        }
        let ownerIsUnread = workspaceUnreadIndicatorIds.contains(tabId)
        if ownerWasUnread != ownerIsUnread {
            refreshWorkspacePanelUnreadPresentation(forTabId: tabId)
        }
        return true
    }

    private func clearPanelDerivedWorkspaceUnread() {
        guard !panelDerivedUnreadWorkspaceIds.isEmpty else { return }
        panelDerivedUnreadWorkspaceIds = []
        refreshUnreadPresentation()
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
        guard mutateWorkspaceRestoredUnread(isUnread, forTabId: tabId) else {
            return false
        }
        refreshUnreadPresentation()
        return true
    }

    /// Mutates restored workspace unread state without publishing a projection.
    @discardableResult
    private func mutateWorkspaceRestoredUnread(_ isUnread: Bool, forTabId tabId: UUID) -> Bool {
        if isUnread {
            return restoredUnreadWorkspaceIds.insert(tabId).inserted
        }
        return restoredUnreadWorkspaceIds.remove(tabId) != nil
    }

    private func clearWorkspaceRestoredUnread() {
        guard !restoredUnreadWorkspaceIds.isEmpty else { return }
        restoredUnreadWorkspaceIds = []
        refreshUnreadPresentation()
    }

    func hasManualUnread(forTabId tabId: UUID) -> Bool { manualUnreadWorkspaceIds.contains(tabId) }

    func hasManualUnread(forTabId tabId: UUID, surfaceId: UUID) -> Bool {
        manualUnreadSurfaceIdsByOwnerId[tabId]?.contains(surfaceId) ?? false
    }

    func hasPanelDerivedUnread(forTabId tabId: UUID) -> Bool { panelDerivedUnreadWorkspaceIds.contains(tabId) }

    func hasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool { restoredUnreadWorkspaceIds.contains(tabId) }

    func hasDismissibleState(forTabId tabId: UUID) -> Bool {
        (indexes.unreadCountByTabId[tabId] ?? 0) > 0 ||
            focusedReadIndicatorByTabId[tabId] != nil ||
            manualUnreadWorkspaceIds.contains(tabId) ||
            manualUnreadSurfaceIdsByOwnerId[tabId]?.isEmpty == false ||
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

    @discardableResult
    func clearManualUnread(forTabId tabId: UUID, surfaceId: UUID) -> Bool {
        setSurfaceManualUnread(false, forTabId: tabId, surfaceId: surfaceId)
    }

    // Per-workspace badges treat workspace indicators as unread activity;
    // summing these counts can exceed indexes.unreadCount.
    func unreadCount(forTabId tabId: UUID) -> Int {
        let hasWorkspaceUnreadIndicator = manualUnreadWorkspaceIds.contains(tabId) ||
            manualUnreadSurfaceIdsByOwnerId[tabId]?.isEmpty == false ||
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
            correlationKey: nil,
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
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        replyShape: TerminalNotificationReplyShape = .none,
        retargetsToLiveSurfaceOwner: Bool = true,
        cooldownKey: String? = nil,
        cooldownInterval: TimeInterval? = nil,
        correlationKey: String? = nil,
        clickAction: TerminalNotificationClickAction? = nil, notificationGeneration: UInt64? = nil,
        resolvedHooks: [CmuxResolvedNotificationHook]? = nil,
        preRegisteredPolicyRequestId: UUID? = nil,
        agent: TerminalNotificationPolicyAgentContext? = nil
    ) {
#if DEBUG
        cmuxDebugLog(
            "notification.store.add workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count) cooldown=\(cooldownKey == nil ? 0 : 1)"
        )
#endif
        let now = Date()
        let resolvedCooldownInterval: TimeInterval?
        if let cooldownInterval, cooldownInterval.isFinite, cooldownInterval > 0 {
            resolvedCooldownInterval = cooldownInterval
        } else {
            resolvedCooldownInterval = nil
        }
        if let cooldownKey,
           let resolvedCooldownInterval,
           let lastNotificationDate = lastNotificationDateByCooldownKey[cooldownKey],
           now.timeIntervalSince(lastNotificationDate) < resolvedCooldownInterval {
#if DEBUG
            cmuxDebugLog(
                "notification.store.add.skip workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId?.uuidString.prefix(8) ?? "nil") reason=cooldown"
            )
#endif
            if let preRegisteredPolicyRequestId {
                abortDesktopNotificationHookResolution(preRegisteredPolicyRequestId)
            }
            return
        }
        let cooldownReservation = makeCooldownReservation(
            key: cooldownKey,
            interval: resolvedCooldownInterval
        )
        if let cooldownReservation {
            lastNotificationDateByCooldownKey[cooldownReservation.key] = now
        }
        let policyContext = makeNotificationPolicyContext(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            replyShape: replyShape,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            correlationKey: correlationKey ?? cooldownKey,
            resolvedHooks: resolvedHooks,
            agent: agent
        )
        if policyContext.hooks.isEmpty, preRegisteredPolicyRequestId == nil {
            inFlightPolicyRequests.discardPending(
                forDeliveryIdentityOf: policyContext.request
            )
            applyNotification(
                request: policyContext.request,
                effects: TerminalNotificationPolicyEffects(),
                now: now,
                cooldownReservation: cooldownReservation,
                scrollPosition: policyContext.scrollPosition,
                clickAction: clickAction
            )
            return
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
                request: policyContext.request,
                effects: TerminalNotificationPolicyEffects(),
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
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
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
                    request: policyContext.request,
                    envelope: envelope,
                    cooldownReservation: cooldownReservation,
                    scrollPosition: policyContext.scrollPosition,
                    clickAction: clickAction
                )
            case .failure(let failure):
                self.completePolicyRequest(
                    policyRequestId,
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    cooldownReservation: cooldownReservation,
                    scrollPosition: policyContext.scrollPosition,
                    clickAction: clickAction
                )
                self.reportNotificationHookFailure(failure)
            }
        }
        inFlightPolicyRequests.attach(task: task, to: policyRequestId)
    }

    private func completePolicyRequest(_ policyRequestId: UUID, request: TerminalNotificationPolicyRequest, envelope: TerminalNotificationPolicyEnvelope, cooldownReservation: NotificationCooldownReservation?, scrollPosition: TerminalNotificationScrollPosition?, clickAction: TerminalNotificationClickAction?) {
        inFlightPolicyRequests.complete(policyRequestId) { [weak self] in
            self?.applyNotification(request: request, envelope: envelope, now: Date(), cooldownReservation: cooldownReservation, scrollPosition: scrollPosition, clickAction: clickAction, policyRequestId: nil)
        }
    }

    private func completePolicyRequest(_ policyRequestId: UUID, request: TerminalNotificationPolicyRequest, effects: TerminalNotificationPolicyEffects, cooldownReservation: NotificationCooldownReservation?, scrollPosition: TerminalNotificationScrollPosition?, clickAction: TerminalNotificationClickAction?) {
        inFlightPolicyRequests.complete(policyRequestId) { [weak self] in
            self?.applyNotification(request: request, effects: effects, now: Date(), cooldownReservation: cooldownReservation, scrollPosition: scrollPosition, clickAction: clickAction, policyRequestId: nil)
        }
    }

    private struct NotificationCooldownReservation: Sendable {
        let key: String
        let previousDate: Date?
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
        cooldownReservation: NotificationCooldownReservation?
    ) -> UUID? {
        let onDiscard: @MainActor @Sendable () -> Void = { [weak self] in
            self?.restoreCooldownReservation(cooldownReservation)
        }
        if let preRegisteredPolicyRequestId {
            guard inFlightPolicyRequests.updateOnDiscard(
                onDiscard,
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
            onDiscard: onDiscard
        )
    }

    private func makeCooldownReservation(
        key: String?,
        interval: TimeInterval?
    ) -> NotificationCooldownReservation? {
        guard let key, interval != nil else { return nil }
        return NotificationCooldownReservation(
            key: key,
            previousDate: lastNotificationDateByCooldownKey[key]
        )
    }
    private func commitCooldownReservation(
        _ reservation: NotificationCooldownReservation?,
        at date: Date
    ) {
        guard let reservation else { return }
        lastNotificationDateByCooldownKey[reservation.key] = date
    }
    private func restoreCooldownReservation(_ reservation: NotificationCooldownReservation?) {
        guard let reservation else { return }
        if let previousDate = reservation.previousDate {
            lastNotificationDateByCooldownKey[reservation.key] = previousDate
        } else {
            lastNotificationDateByCooldownKey.removeValue(forKey: reservation.key)
        }
    }

    private func makeNotificationPolicyContext(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        replyShape: TerminalNotificationReplyShape = .none,
        retargetsToLiveSurfaceOwner: Bool,
        correlationKey: String?,
        resolvedHooks: [CmuxResolvedNotificationHook]?,
        agent: TerminalNotificationPolicyAgentContext? = nil
    ) -> NotificationPolicyContext {
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
        let panelId = surfaceId.flatMap {
            workspace?.surfaceOwnershipTarget(for: $0)?.containerPanelID
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
                correlationKey: correlationKey,
                title: title,
                subtitle: subtitle,
                body: body,
                replyShape: replyShape,
                cwd: cwd,
                isAppFocused: isAppFocused,
                isFocusedPanel: isFocusedPanel,
                agent: agent
            ),
            scrollPosition: scrollPosition,
            hooks: resolvedHooks ?? cmuxConfigStore?.notificationHooks(
                startingFrom: workspace?.isRemoteWorkspace == true ? nil : cwd
            ) ?? [],
            globalConfigPath: cmuxConfigStore?.globalConfigPath
        )
    }
    private func applyNotification(
        request: TerminalNotificationPolicyRequest,
        envelope: TerminalNotificationPolicyEnvelope,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?,
        scrollPosition: TerminalNotificationScrollPosition?,
        clickAction: TerminalNotificationClickAction?, policyRequestId: UUID?
    ) {
        let payload = envelope.notification
        applyNotification(
            request: TerminalNotificationPolicyRequest(
                tabId: request.tabId,
                surfaceId: request.surfaceId,
                panelId: request.panelId,
                retargetsToLiveSurfaceOwner: request.retargetsToLiveSurfaceOwner,
                correlationKey: request.correlationKey,
                title: payload.title,
                subtitle: payload.subtitle,
                body: payload.body,
                replyShape: request.replyShape,
                cwd: request.cwd,
                isAppFocused: request.isAppFocused,
                isFocusedPanel: request.isFocusedPanel,
                agent: request.agent
            ),
            effects: envelope.effects,
            now: now,
            cooldownReservation: cooldownReservation,
            scrollPosition: scrollPosition,
            clickAction: clickAction, policyRequestId: policyRequestId
        )
    }

    private func applyNotification(
        request: TerminalNotificationPolicyRequest,
        effects: TerminalNotificationPolicyEffects,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?,
        scrollPosition: TerminalNotificationScrollPosition?,
        clickAction: TerminalNotificationClickAction?, policyRequestId: UUID? = nil
    ) {
        guard inFlightPolicyRequests.claim(policyRequestId) else { return }
        guard let request = notificationPolicyRequestAtLiveOwner(request) else { restoreCooldownReservation(cooldownReservation); return }
        let shouldSuppressExternalDelivery = shouldSuppressExternalDelivery(
            tabId: request.tabId,
            surfaceId: request.surfaceId
        )
        let notification = TerminalNotification(
            id: UUID(),
            tabId: request.tabId,
            surfaceId: request.surfaceId,
            panelId: request.panelId,
            retargetsToLiveSurfaceOwner: request.retargetsToLiveSurfaceOwner,
            correlationKey: request.correlationKey,
            title: request.title,
            subtitle: request.subtitle,
            body: request.body,
            createdAt: now,
            isRead: !effects.markUnread,
            paneFlash: effects.paneFlash,
            scrollPosition: scrollPosition,
            clickAction: clickAction,
            replyShape: request.replyShape
        )
        if effects.record {
            recordNotification(
                notification,
                shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
                effects: effects,
                now: now,
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
            commitCooldownReservation(cooldownReservation, at: now)
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
        now: Date,
        cooldownReservation: NotificationCooldownReservation?
    ) {
        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == notification.tabId, existing.surfaceId == notification.surfaceId else { return false }
            if let correlationKey = notification.correlationKey {
                // Correlated producers (Cursor approvals and other
                // identity-scoped events) replace only their own prior entry.
                // A refresh must not erase a newer unrelated question, error,
                // or approval that arrived on the same surface.
                guard existing.correlationKey == correlationKey else { return false }
            }
            idsToClear.append(existing.id.uuidString)
            return true
        }

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

        updated.insert(notification, at: 0)
        mutateWorkspaceManualUnread(false, forTabId: notification.tabId)
        if let surfaceId = notification.surfaceId {
            mutateSurfaceManualUnread(
                false,
                forTabId: notification.tabId,
                surfaceId: surfaceId
            )
        }
        notifications = updated
        notificationFeedHistory.record(
            notification,
            supersededIDs: Set(idsToClear.compactMap { UUID(uuidString: $0) })
        )
        commitCooldownReservation(cooldownReservation, at: now)
#if DEBUG
        cmuxDebugLog(
            "notification.store.record workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") removed=\(idsToClear.count) unread=\(!notification.isRead ? 1 : 0) paneFlash=\(notification.paneFlash ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0) total=\(notifications.count)"
        )
#endif
        if !idsToClear.isEmpty {
            removeDeliveredNotifications(withIdentifiers: idsToClear)
            removePendingNotificationRequests(withIdentifiers: idsToClear)
            // Decide replacement admission exactly once in the side-effect
            // chokepoint below. Until then, retain the superseded ids so the
            // actual queue result determines whether dismissal is immediate or
            // ordered after the replacement.
            recordDismissTombstones(
                ids: idsToClear.compactMap { UUID(uuidString: $0) }
            )
            supersededPhoneDismissBuffer.stash(
                ids: idsToClear,
                forKey: SupersededPhoneDismissBuffer.key(
                    tabId: notification.tabId,
                    surfaceId: notification.surfaceId
                )
            )
        }
        deliverNotificationSideEffects(
            notification,
            shouldSuppressExternalDelivery: shouldSuppressExternalDelivery,
            effects: effects
        )
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
#if DEBUG
        cmuxDebugLog(
            "notification.store.sideEffects workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") desktop=\(effects.desktop ? 1 : 0) sound=\(effects.sound ? 1 : 0) command=\(effects.command ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0)"
        )
#endif
        if effects.desktop || effects.sound || effects.command {
            if shouldSuppressExternalDelivery {
                suppressedNotificationFeedbackHandler(self, notification, effects)
            } else {
                notificationDeliveryHandler(self, notification, effects)
            }
        }

        let key = SupersededPhoneDismissBuffer.key(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId
        )
        let shouldAttemptPhone = !shouldSuppressExternalDelivery
            && Self.shouldAttemptPhoneForward(
                effects: effects,
                phoneForwardingEnabled: PhonePushClient.shared
                    .configuration().forwardingEnabled,
                categoryAllowsDelivery: true
            )
        if shouldAttemptPhone {
            PhonePushClient.shared.forward(
                notification,
                badgeCount: indexes.unreadCount
            )
        }
        let superseded = supersededPhoneDismissBuffer.flush(forKey: key)
        if !superseded.isEmpty {
            // The replacement enqueue above and this dismissal enter the same
            // serial delivery queue synchronously, so ordering already holds.
            emitNotificationsDismissed(ids: superseded)
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
            Task { [userNotificationCenter] in
                let result = await userNotificationCenter.add(request)
                if case .failure(let error) = result {
                    terminalNotificationLogger.error(
                        "Failed to schedule notification hook failure alert error=\(String(describing: error), privacy: .private)"
                    )
                    NotificationSoundSettings.playSelectedSound()
                }
            }
        }
    }

    func markRead(id: UUID) {
        _ = markNotificationFeedRead(ids: [id])
    }

    /// Marks chronological-feed records read and mirrors matching active Mac
    /// notifications through the existing banner, badge, and dismiss-sync path.
    @discardableResult
    func markNotificationFeedRead(ids: Set<UUID>) -> Int {
        let marked = notificationFeedHistory.markRead(ids: ids)
        guard !ids.isEmpty else { return marked }
        var updated = notifications
        var activeIDs: [String] = []
        var drainedSuperseded: [String] = []
        for index in updated.indices where ids.contains(updated[index].id) && !updated[index].isRead {
            updated[index].isRead = true
            activeIDs.append(updated[index].id.uuidString)
            drainedSuperseded.append(contentsOf: supersededPhoneDismissBuffer.flush(
                forKey: SupersededPhoneDismissBuffer.key(
                    tabId: updated[index].tabId,
                    surfaceId: updated[index].surfaceId
                )
            ))
        }
        if !activeIDs.isEmpty {
            notifications = updated
            removeDeliveredNotifications(withIdentifiers: activeIDs)
            emitNotificationsDismissed(
                ids: activeIDs,
                drainedSuperseded: drainedSuperseded
            )
        }
        return marked
    }

    func markUnread(id: UUID) {
        _ = markNotificationFeedUnread(ids: [id])
    }

    /// Marks chronological-feed records unread and mirrors matching active Mac
    /// notifications without redelivering their system banners.
    @discardableResult
    func markNotificationFeedUnread(ids: Set<UUID>) -> Int {
        let marked = notificationFeedHistory.markUnread(ids: ids)
        guard !ids.isEmpty else { return marked }
        var updated = notifications
        var tabIDs = Set<UUID>()
        var surfaceKeys = Set<SidebarSurfaceUnreadKey>()
        for index in updated.indices where ids.contains(updated[index].id) && updated[index].isRead {
            updated[index].isRead = false
            tabIDs.insert(updated[index].tabId)
            surfaceKeys.insert(SidebarSurfaceUnreadKey(
                workspaceId: updated[index].tabId,
                surfaceId: updated[index].surfaceId
            ))
        }
        // The notification itself now provides the workspace unread indicator. Clear any
        // existing manual or restored workspace unread state for the same tab so we don't
        // double-count it. (Mirrors what markLatestNotificationAsOldestUnread does for the
        // manual flag — restored hints are a one-time signal from a previous session and
        // should also defer to the concrete unread notification.)
        for tabID in tabIDs {
            mutateWorkspaceManualUnread(false, forTabId: tabID)
            mutateWorkspaceRestoredUnread(false, forTabId: tabID)
        }
        mutateSurfaceManualUnread(false, for: surfaceKeys)
        if !tabIDs.isEmpty {
            notifications = updated
        }
        return marked
    }

    func markRead(forTabId tabId: UUID) {
        inFlightPolicyRequests.discard(forTabId: tabId, surfaceId: nil)
        notificationFeedHistory.markRead(inWorkspace: tabId)
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId && !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
        }
        clearFocusedReadIndicator(forTabId: tabId)
        clearManualUnread(forTabId: tabId)
        clearSurfaceManualUnread(forTabId: tabId)
        clearWorkspacePanelUnread(forTabId: tabId)
        setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
        if !idsToClear.isEmpty {
            removeDeliveredNotifications(withIdentifiers: idsToClear)
            emitNotificationsDismissed(
                ids: idsToClear,
                drainedSuperseded: supersededPhoneDismissBuffer.flush(matchingTabId: tabId)
            )
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        inFlightPolicyRequests.discard(forTabId: tabId, surfaceId: surfaceId)
        notificationFeedHistory.markRead(inWorkspace: tabId, surfaceId: surfaceId)
        var updated = notifications
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
            notifications = updated
        }
        if let surfaceId {
            clearManualUnread(forTabId: tabId, surfaceId: surfaceId)
        } else {
            clearManualUnread(forTabId: tabId)
            clearSurfaceManualUnread(forTabId: tabId)
        }
        if surfaceId == nil {
            // Whole-tab mark-read dismisses every indicator kind, matching
            // markRead(forTabId:). A surface-scoped mark-read must not clear the
            // focused-read indicator: it marks notifications that were already
            // read while the surface was focused, so it outlives mark-read and
            // only an explicit clearFocusedReadIndicator dismisses it.
            clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
            clearWorkspacePanelUnread(forTabId: tabId)
            setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
            setWorkspaceRestoredUnread(false, forTabId: tabId)
        }
        if !idsToClear.isEmpty {
            removeDeliveredNotifications(withIdentifiers: idsToClear)
            removePendingNotificationRequests(withIdentifiers: idsToClear)
            emitNotificationsDismissed(ids: idsToClear, drainedSuperseded: supersededDrained)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        setWorkspaceManualUnread(true, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
    }

    func markUnread(forTabId tabId: UUID, surfaceId: UUID) {
        markWindowDockSurfaceUnread(windowId: tabId, surfaceId: surfaceId)
    }

    @discardableResult
    func markWindowDockSurfaceUnread(windowId: UUID, surfaceId: UUID) -> Bool {
        setSurfaceManualUnread(true, forTabId: windowId, surfaceId: surfaceId)
    }

    @discardableResult
    func clearWindowDockSurfaceUnread(windowId: UUID, surfaceId: UUID) -> Bool {
        setSurfaceManualUnread(false, forTabId: windowId, surfaceId: surfaceId)
    }

    @discardableResult
    func markLatestWindowDockNotificationAsOldestUnread(
        windowId: UUID,
        surfaceId: UUID
    ) -> UUID? {
        var updated = notifications
        guard let index = updated.firstIndex(where: {
            $0.matches(tabId: windowId, surfaceId: surfaceId)
        }) else {
            return nil
        }
        return moveNotificationToOldestUnread(at: index, in: &updated)
    }

    @discardableResult
    func markLatestNotificationAsOldestUnread(forTabId tabId: UUID, surfaceId: UUID?) -> UUID? {
        var updated = notifications
        guard let index = latestNotificationIndex(forTabId: tabId, surfaceId: surfaceId, in: updated) else {
            if surfaceId == nil, !workspaceIsUnread(forTabId: tabId) {
                setWorkspaceManualUnread(true, forTabId: tabId)
            }
            return nil
        }

        return moveNotificationToOldestUnread(at: index, in: &updated)
    }

    private func moveNotificationToOldestUnread(
        at index: Int,
        in updated: inout [TerminalNotification]
    ) -> UUID {
        var notification = updated.remove(at: index)
        notification.isRead = false
        let insertionIndex = updated.lastIndex(where: { !$0.isRead }).map { $0 + 1 } ?? updated.endIndex
        updated.insert(notification, at: insertionIndex)
        mutateWorkspaceManualUnread(false, forTabId: notification.tabId)
        if let notificationSurfaceId = notification.surfaceId {
            mutateSurfaceManualUnread(
                false,
                forTabId: notification.tabId,
                surfaceId: notificationSurfaceId
            )
        }
        notifications = updated
        notificationFeedHistory.markUnread(ids: [notification.id])
        return notification.id
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
        notificationFeedHistory.markAllRead()
        var updated = notifications
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
            notifications = updated
        }
        clearWorkspaceManualUnread()
        clearSurfaceManualUnread()
        clearAllWorkspacePanelUnread(forTabIds: tabIdsToClearPanelUnread)
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        if !idsToClear.isEmpty {
            removeDeliveredNotifications(withIdentifiers: idsToClear)
            removePendingNotificationRequests(withIdentifiers: idsToClear)
            emitNotificationsDismissed(
                ids: idsToClear,
                drainedSuperseded: supersededPhoneDismissBuffer.flushAll()
            )
        }
    }

    func remove(id: UUID) {
        var updated = notifications
        let removed = updated.first(where: { $0.id == id })
        let originalCount = updated.count
        updated.removeAll { $0.id == id }
        guard updated.count != originalCount else { return }
        notifications = updated
        notificationFeedHistory.markRead(ids: [id])
        if let removed {
            clearFocusedReadIndicator(forTabId: removed.tabId, surfaceId: removed.surfaceId)
        }
        removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        let supersededDrained = removed.map { removedNotification in
            supersededPhoneDismissBuffer.flush(
                forKey: SupersededPhoneDismissBuffer.key(
                    tabId: removedNotification.tabId,
                    surfaceId: removedNotification.surfaceId
                )
            )
        } ?? []
        emitNotificationsDismissed(ids: [id.uuidString], drainedSuperseded: supersededDrained)
    }

    func clearNotifications(forTabId tabId: UUID, correlationKey: String) {
        inFlightPolicyRequests.discard(forTabId: tabId, correlationKey: correlationKey)
        let ids = notifications.compactMap {
            $0.tabId == tabId && $0.correlationKey == correlationKey ? $0.id : nil
        }
        ids.forEach(remove)
        removePendingNotificationRequests(withIdentifiers: ids.map(\.uuidString))
    }

    /// Clears one surface notification by its producer correlation key. This
    /// is intentionally narrower than a surface clear: a completion callback
    /// may arrive after a newer question, error, or approval was delivered to
    /// the same pane.
    func clearNotifications(
        forTabId tabId: UUID,
        surfaceId: UUID,
        correlationKey: String,
        throughNotificationGeneration: UInt64? = nil
    ) {
        inFlightPolicyRequests.discard(
            forSurfaceId: surfaceId,
            correlationKey: correlationKey,
            through: throughNotificationGeneration
        )
        let liveTabId = AppDelegate.shared?
            .agentNotificationDeliveryTarget(claimedTabId: tabId, surfaceId: surfaceId)?.tabId ?? tabId
        let ids = notifications.compactMap { notification in
            guard notification.correlationKey == correlationKey,
                  notification.matchesClear(
                      tabId: tabId,
                      liveTabId: liveTabId,
                      surfaceId: surfaceId
                  ) else {
                return nil
            }
            return notification.id
        }
        ids.forEach(remove)
        removePendingNotificationRequests(withIdentifiers: ids.map(\.uuidString))
    }

    func restoreSessionNotifications(_ restoredNotifications: [TerminalNotification], forTabId tabId: UUID) {
        TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId)

        let removedIds = notifications
            .filter { $0.tabId == tabId }
            .map { $0.id.uuidString }
        var usedNotificationIds = Set(notifications.filter { $0.tabId != tabId }.map(\.id))
        let restoredForTab = restoredNotifications
            .filter { $0.tabId == tabId }
            .sorted(by: Self.notificationSortPrecedes)
            .map { Self.notificationWithUniqueId($0, usedIds: &usedNotificationIds) }
        let keptNotifications = notifications.filter { $0.tabId != tabId }
        let nextNotifications = (restoredForTab + keptNotifications).sorted(by: Self.notificationSortPrecedes)

        let didChangeNotifications = nextNotifications != notifications
        if didChangeNotifications {
            notifications = nextNotifications
        }
        notificationFeedHistory.reconcileActiveNotifications(nextNotifications)
        let nextIDs = Set(nextNotifications.map(\.id))
        notificationFeedHistory.markRead(
            ids: Set(removedIds.compactMap { UUID(uuidString: $0) }).subtracting(nextIDs)
        )
        clearFocusedReadIndicator(forTabId: tabId)

        if didChangeNotifications, !removedIds.isEmpty {
            removeDeliveredNotifications(withIdentifiers: removedIds)
            removePendingNotificationRequests(withIdentifiers: removedIds)
        }
    }

    private static func notificationWithUniqueId(
        _ notification: TerminalNotification,
        usedIds: inout Set<UUID>
    ) -> TerminalNotification {
        if usedIds.insert(notification.id).inserted {
            return notification
        }

        var replacementId = UUID()
        while !usedIds.insert(replacementId).inserted {
            replacementId = UUID()
        }
        return TerminalNotification(
            id: replacementId,
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            panelId: notification.panelId,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            correlationKey: notification.correlationKey,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            scrollPosition: notification.scrollPosition,
            clickAction: notification.clickAction,
            replyShape: notification.replyShape
        )
    }

    private func replaceNotificationsForClear(_ next: [TerminalNotification]) { suppressNotificationDiffPublishing = true; notifications = next; suppressNotificationDiffPublishing = false }
    func clearAll(discardQueuedNotifications: Bool = true, throughNotificationGeneration: UInt64? = nil) {
        inFlightPolicyRequests.discardAll(through: throughNotificationGeneration)
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotifications() }
        guard !notifications.isEmpty ||
            !focusedReadIndicatorByTabId.isEmpty ||
            !manualUnreadWorkspaceIds.isEmpty ||
            !manualUnreadSurfaceIdsByOwnerId.isEmpty ||
            !panelDerivedUnreadWorkspaceIds.isEmpty ||
            !restoredUnreadWorkspaceIds.isEmpty else { return }
        let tabIdsToClearPanelUnread = panelDerivedUnreadWorkspaceIds.union(notifications.map(\.tabId))
        let ids = notifications.map { $0.id.uuidString }
        notificationFeedHistory.markRead(
            ids: Set(ids.compactMap { UUID(uuidString: $0) })
        )
        replaceNotificationsForClear([])
        clearWorkspaceManualUnread()
        clearSurfaceManualUnread()
        clearAllWorkspacePanelUnread(forTabIds: tabIdsToClearPanelUnread)
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        focusedReadIndicatorByTabId.removeAll()
        CmuxEventBus.shared.publishNotificationCleared(ids: ids, workspaceId: nil, surfaceId: nil)
        removeDeliveredNotifications(withIdentifiers: ids)
        removePendingNotificationRequests(withIdentifiers: ids)
        emitNotificationsDismissed(ids: ids, drainedSuperseded: supersededPhoneDismissBuffer.flushAll())
    }

    func clearNotifications(
        forTabId tabId: UUID,
        surfaceId: UUID?,
        discardQueuedNotifications: Bool = true, throughNotificationGeneration: UInt64? = nil
    ) {
        let liveTabId = surfaceId.flatMap { AppDelegate.shared?.agentNotificationDeliveryTarget(claimedTabId: tabId, surfaceId: $0)?.tabId } ?? tabId
        let tabIds = Set([tabId, liveTabId])
        inFlightPolicyRequests.discard(forTabId: tabId, surfaceId: surfaceId, through: throughNotificationGeneration)
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotificationsForClear(tabId: liveTabId, surfaceId: surfaceId) }
        let hadRestoredWorkspaceUnread = surfaceId == nil && restoredUnreadWorkspaceIds.contains(tabId)
        let hadSurfaceManualUnread: Bool
        if let surfaceId {
            hadSurfaceManualUnread = tabIds.contains {
                hasManualUnread(forTabId: $0, surfaceId: surfaceId)
            }
        } else {
            hadSurfaceManualUnread = tabIds.contains {
                manualUnreadSurfaceIdsByOwnerId[$0]?.isEmpty == false
            }
        }
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = [], indicatorTabIds: Set<UUID> = [tabId]
        var supersededDrained: [String] = []
        for notification in notifications {
            if notification.matchesClear(tabId: tabId, liveTabId: liveTabId, surfaceId: surfaceId) {
                idsToClear.append(notification.id.uuidString); indicatorTabIds.insert(notification.tabId)
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
        let hadFocusedReadIndicator = indicatorTabIds.contains { focusedReadIndicatorByTabId[$0].map { $0 == surfaceId } ?? false }
        guard !idsToClear.isEmpty || hadFocusedReadIndicator ||
            hadRestoredWorkspaceUnread || hadSurfaceManualUnread else { return }
        if !idsToClear.isEmpty {
            notificationFeedHistory.markRead(
                ids: Set(idsToClear.compactMap { UUID(uuidString: $0) })
            )
            replaceNotificationsForClear(updated)
        }
        if surfaceId == nil {
            setWorkspaceRestoredUnread(false, forTabId: tabId)
            tabIds.forEach { clearSurfaceManualUnread(forTabId: $0) }
        } else if let surfaceId {
            tabIds.forEach {
                setSurfaceManualUnread(false, forTabId: $0, surfaceId: surfaceId)
            }
        }
        indicatorTabIds.forEach { clearFocusedReadIndicator(forTabId: $0, surfaceId: surfaceId) }
        if !idsToClear.isEmpty {
            CmuxEventBus.shared.publishNotificationCleared(ids: idsToClear, workspaceId: tabIds.count == 1 ? tabId : nil, surfaceId: surfaceId)
            removeDeliveredNotifications(withIdentifiers: idsToClear)
            removePendingNotificationRequests(withIdentifiers: idsToClear)
            emitNotificationsDismissed(ids: idsToClear, drainedSuperseded: supersededDrained)
        }
    }

    func rebindSurfaceNotifications(fromTabId sourceTabId: UUID, toTabId destinationTabId: UUID, surfaceId: UUID) {
        guard sourceTabId != destinationTabId else { return }
        inFlightPolicyRequests.rebindSurface(fromTabId: sourceTabId, toTabId: destinationTabId, surfaceId: surfaceId)
        notificationFeedHistory.rebindSurface(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            surfaceId: surfaceId
        )
        var didMoveNotification = false
        let updated = notifications.map { notification -> TerminalNotification in
            guard notification.retargetsToLiveSurfaceOwner,
                  notification.matches(tabId: sourceTabId, surfaceId: surfaceId) else {
                return notification
            }
            didMoveNotification = true
            return TerminalNotification(
                id: notification.id,
                tabId: destinationTabId,
                surfaceId: notification.surfaceId,
                panelId: notification.panelId,
                correlationKey: notification.correlationKey,
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body,
                createdAt: notification.createdAt,
                isRead: notification.isRead,
                paneFlash: notification.paneFlash,
                scrollPosition: notification.scrollPosition,
                clickAction: notification.clickAction,
                replyShape: notification.replyShape
            )
        }
        if didMoveNotification {
            notifications = updated
        }
        if didMoveNotification, focusedReadIndicatorByTabId[sourceTabId] == surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: sourceTabId)
            if focusedReadIndicatorByTabId[destinationTabId] == nil {
                focusedReadIndicatorByTabId[destinationTabId] = surfaceId
            }
        }
    }
    func clearNotifications(forTabId tabId: UUID, discardQueuedNotifications: Bool = true, throughNotificationGeneration: UInt64? = nil) {
        inFlightPolicyRequests.discard(forTabId: tabId, surfaceId: nil, through: throughNotificationGeneration)
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotificationsForClear(tabId: tabId, surfaceId: nil) }
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
        clearManualUnread(forTabId: tabId)
        clearSurfaceManualUnread(forTabId: tabId)
        clearWorkspacePanelUnread(forTabId: tabId)
        setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
        guard !idsToClear.isEmpty || hadFocusedReadIndicator else { return }
        if !idsToClear.isEmpty {
            notificationFeedHistory.markRead(
                ids: Set(idsToClear.compactMap { UUID(uuidString: $0) })
            )
            replaceNotificationsForClear(updated)
        }
        clearFocusedReadIndicator(forTabId: tabId)
        if !idsToClear.isEmpty {
            CmuxEventBus.shared.publishNotificationCleared(ids: idsToClear, workspaceId: tabId, surfaceId: nil)
            removeDeliveredNotifications(withIdentifiers: idsToClear)
            removePendingNotificationRequests(withIdentifiers: idsToClear)
            emitNotificationsDismissed(
                ids: idsToClear,
                drainedSuperseded: supersededPhoneDismissBuffer.flush(matchingTabId: tabId)
            )
        }
    }

    private func resolvedNotificationTitle(for notification: TerminalNotification) -> String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
        return notification.title.isEmpty ? appName : notification.title
    }

    private func scheduleUserNotification(
        _ notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard effects.desktop else {
            playLocalNotificationFeedback(
                title: resolvedNotificationTitle(for: notification),
                subtitle: notification.subtitle,
                body: notification.body,
                effects: effects
            )
            return
        }

        let nativeDeliveryHooks = nativeNotificationDeliveryHooks
        let notificationTitle = resolvedNotificationTitle(for: notification)
        let notificationSubtitle = notification.subtitle
        let notificationBody = notification.body
        let notificationId = notification.id
        let notificationTabId = notification.tabId
        let notificationSurfaceId = notification.surfaceId
        let retargetsToLiveSurfaceOwner = notification.retargetsToLiveSurfaceOwner
        let clickActionUserInfo = notification.clickAction?.userInfo ?? [:]
        let categoryIdentifier = notification.replyShape == .text
            ? Self.textReplyCategoryIdentifier
            : Self.categoryIdentifier
        let handleAuthorization: NativeNotificationDeliveryHooks.AuthorizationCompletion = { authorized, effectiveAuthorizationState in
            let content = UNMutableNotificationContent()
            content.title = notificationTitle
            content.subtitle = notificationSubtitle
            content.body = notificationBody
            guard authorized else {
                nativeDeliveryHooks.playUnavailableFeedback(
                    effects: Self.fallbackEffects(effects, authorizationState: effectiveAuthorizationState)
                )
                return
            }
            content.sound = effects.sound ? NotificationSoundSettings.sound() : nil
            content.categoryIdentifier = categoryIdentifier
            content.userInfo = [
                "tabId": notificationTabId.uuidString,
                "notificationId": notificationId.uuidString,
                Self.retargetsToLiveSurfaceOwnerUserInfoKey: retargetsToLiveSurfaceOwner,
            ]
            if let surfaceId = notificationSurfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }
            for (key, value) in clickActionUserInfo {
                content.userInfo[key] = value
            }
            let request = UNNotificationRequest(
                identifier: notificationId.uuidString,
                content: content,
                trigger: nil
            )
            let commandTitle = content.title
            let commandSubtitle = content.subtitle
            let commandBody = content.body

            nativeDeliveryHooks.schedule(request) { error in
                if let error {
                    terminalNotificationLogger.error(
                        "Failed to schedule notification error=\(error.localizedDescription, privacy: .private)"
                    )
                    nativeDeliveryHooks.playUnavailableFeedback(effects: effects)
                } else if effects.command {
                    nativeDeliveryHooks.runCommand(title: commandTitle, subtitle: commandSubtitle, body: commandBody)
                }
            }
        }
        if !nativeDeliveryHooks.authorizeForTesting(handleAuthorization) {
            ensureAuthorization(origin: .notificationDelivery, handleAuthorization)
        }
    }

    private func playSuppressedNotificationFeedback(
        for notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        nativeNotificationDeliveryHooks.runLocalFeedback(
            title: resolvedNotificationTitle(for: notification),
            subtitle: notification.subtitle,
            body: notification.body,
            effects: effects
        )
    }

    private func playLocalNotificationFeedback(
        title: String,
        subtitle: String,
        body: String,
        effects: TerminalNotificationPolicyEffects
    ) {
        nativeNotificationDeliveryHooks.runLocalFeedback(
            title: title,
            subtitle: subtitle,
            body: body,
            effects: effects
        )
    }

    /// `completion` receives the decision plus the effective authorization
    /// state behind it. The state matters for the just-prompted-and-declined
    /// case: `authorizationState` is refreshed asynchronously there, so a
    /// caller reading the property would still see `.notDetermined` and play
    /// the fallback sound for the very notification whose prompt the user
    /// just denied.
    private func ensureAuthorization(
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
        Task { @MainActor [weak self, userNotificationCenter] in
            let result = await userNotificationCenter.authorizationStatus()
            guard let self else {
                completion(false, .unknown)
                return
            }
            guard case .success(let status) = result else {
                authorizationState = .unknown
                logAuthorization("ensure unavailable origin=\(origin.rawValue) result=\(String(describing: result))")
                completion(false, .unknown)
                return
            }

            authorizationState = Self.authorizationState(from: status)
            logAuthorization(
                "ensure status origin=\(origin.rawValue) status=\(Self.authorizationStatusLabel(status)) mapped=\(authorizationState.statusLabel) appActive=\(AppFocusState.isAppActive())"
            )
            switch status {
            case .authorized, .provisional, .ephemeral:
                completion(true, authorizationState)
            case .denied:
                if origin != .notificationDelivery {
                    logAuthorization("ensure denied origin=\(origin.rawValue) prompting_settings")
                    promptToEnableNotifications()
                }
                completion(false, .denied)
            case .notDetermined:
                if Self.shouldDeferAutomaticAuthorizationRequest(
                    origin: origin,
                    status: status,
                    isAppActive: AppFocusState.isAppActive()
                ) {
                    logAuthorization("ensure deferred origin=\(origin.rawValue)")
                    hasDeferredAuthorizationRequest = true
                    completion(false, .notDetermined)
                } else {
                    requestAuthorizationIfNeeded(origin: origin, completion)
                }
            case .unknown:
                logAuthorization("ensure unknown status origin=\(origin.rawValue)")
                completion(false, .unknown)
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
        Task { @MainActor [weak self, userNotificationCenter] in
            let result = await userNotificationCenter.requestAuthorization(
                options: [.alert, .sound]
            )
            guard let self else {
                completion(false, .unknown)
                return
            }
            switch result {
            case .success(let granted):
                if granted {
                    authorizationState = .authorized
                } else {
                    refreshAuthorizationStatus()
                }
                logAuthorization(
                    "request callback origin=\(origin.rawValue) granted=\(granted) error=nil mapped=\(authorizationState.statusLabel)"
                )
                let effectiveState: NotificationAuthorizationState =
                    granted ? .authorized : .denied
                completion(granted, effectiveState)
            case .failure(let error):
                refreshAuthorizationStatus()
                logAuthorization(
                    "request callback origin=\(origin.rawValue) granted=false error=\(String(describing: error)) mapped=\(authorizationState.statusLabel)"
                )
                completion(false, .unknown)
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

    static func authorizationState(
        from status: UserNotificationAuthorizationStatus
    ) -> NotificationAuthorizationState {
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
        case .unknown:
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
        status: UserNotificationAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        guard origin == .notificationDelivery else { return false }
        return status == .notDetermined && !isAppActive
    }

    private static func buildIndexes(for notifications: [TerminalNotification]) -> NotificationIndexes {
        var indexes = NotificationIndexes()
        for notification in notifications {
            if indexes.latestByTabId[notification.tabId] == nil {
                indexes.latestByTabId[notification.tabId] = notification
            }
            guard !notification.isRead else { continue }
            indexes.unreadCount += 1
            indexes.unreadCountByTabId[notification.tabId, default: 0] += 1
            indexes.unreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            if let panelId = notification.panelId, panelId != notification.surfaceId {
                indexes.unreadByTabSurface.insert(
                    TabSurfaceKey(tabId: notification.tabId, surfaceId: panelId)
                )
            }
            if indexes.latestUnreadByTabId[notification.tabId] == nil {
                indexes.latestUnreadByTabId[notification.tabId] = notification
            }
        }
        return indexes
    }

    static func notificationSortPrecedes(_ lhs: TerminalNotification, _ rhs: TerminalNotification) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
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

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        TerminalMutationBus.shared.discardPendingNotifications()
        self.notifications = notifications
        notificationFeedHistory = NotificationFeedHistoryStore(fileURL: nil) { revision in
            MobileHostService.emitEvent(
                topic: Self.feedChangedEventTopic,
                payload: ["revision": revision]
            )
        }
        clearWorkspaceManualUnread()
        clearSurfaceManualUnread()
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        focusedReadIndicatorByTabId.removeAll()
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
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
