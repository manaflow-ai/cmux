import CmuxFoundation
import AppKit
import Foundation
import os
import UserNotifications
import Bonsplit
import CmuxSettings

nonisolated private let terminalNotificationLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification"
)

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

enum TerminalNotificationClickAction: Codable, Hashable, Sendable {
    case revealInFinder(path: String)

    private static let kindUserInfoKey = "cmuxClickAction"
    private static let revealInFinderPathUserInfoKey = "cmuxRevealInFinderPath"
    private static let revealInFinderKind = "revealInFinder"

    var userInfo: [String: String] {
        switch self {
        case .revealInFinder(let path):
            return [
                Self.kindUserInfoKey: Self.revealInFinderKind,
                Self.revealInFinderPathUserInfoKey: path,
            ]
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo[Self.kindUserInfoKey] as? String else { return nil }
        switch kind {
        case Self.revealInFinderKind:
            guard let path = userInfo[Self.revealInFinderPathUserInfoKey] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .revealInFinder(path: path)
        default:
            return nil
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

    static let shared = TerminalNotificationStore()

    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"

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
    private var nativeNotificationDeliveryHooks = NativeNotificationDeliveryHooks()
    private var suppressedNotificationFeedbackHandler: (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void = {
        store,
        notification,
        effects in
        store.playSuppressedNotificationFeedback(for: notification, effects: effects)
    }
    private struct NotificationHookFailureThrottleKey: Hashable {
        let hookId: String
        let sourcePath: String?
    }

    private static let notificationHookFailureThrottle: TimeInterval = 300
    private var lastNotificationDateByCooldownKey: [String: Date] = [:]
    private var lastNotificationHookFailureDateByKey: [NotificationHookFailureThrottleKey: Date] = [:]
    private var indexes = NotificationIndexes()

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
        workspaceUnreadIndicatorIds.count
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
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIds
        )
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

    func hasManualUnread(forTabId tabId: UUID) -> Bool {
        manualUnreadWorkspaceIds.contains(tabId)
    }

    func hasPanelDerivedUnread(forTabId tabId: UUID) -> Bool {
        panelDerivedUnreadWorkspaceIds.contains(tabId)
    }

    func hasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool {
        restoredUnreadWorkspaceIds.contains(tabId)
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

    func addNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        agentId: String? = nil,
        cooldownKey: String? = nil,
        cooldownInterval: TimeInterval? = nil,
        clickAction: TerminalNotificationClickAction? = nil
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
            return
        }
        let cooldownReservation = makeCooldownReservation(
            key: cooldownKey,
            interval: resolvedCooldownInterval
        )
        if let cooldownReservation {
            lastNotificationDateByCooldownKey[cooldownReservation.key] = now
        }
        let workspaceTitle = resolvedWorkspaceTitle(forTabId: tabId)

        let policyContext = makeNotificationPolicyContext(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body
        )
        guard !policyContext.hooks.isEmpty else {
            applyNotification(
                request: policyContext.request,
                effects: TerminalNotificationPolicyEffects(),
                now: now,
                cooldownReservation: cooldownReservation,
                agentId: agentId,
                workspaceTitle: workspaceTitle,
                clickAction: clickAction
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let authorizedHooks = await NotificationPolicyHookAuthorizer.authorize(
                policyContext.hooks,
                globalConfigPath: policyContext.globalConfigPath
            )
            guard !authorizedHooks.isEmpty else {
                self.applyNotification(
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    now: Date(),
                    cooldownReservation: cooldownReservation,
                    agentId: agentId,
                    workspaceTitle: workspaceTitle,
                    clickAction: clickAction
                )
                return
            }

            let result = await TerminalNotificationPolicyEngine.evaluate(
                request: policyContext.request,
                hooks: authorizedHooks
            )
            switch result {
            case .success(let envelope):
                self.applyNotification(
                    request: policyContext.request,
                    envelope: envelope,
                    now: Date(),
                    cooldownReservation: cooldownReservation,
                    agentId: agentId,
                    workspaceTitle: workspaceTitle,
                    clickAction: clickAction
                )
            case .failure(let failure):
                self.applyNotification(
                    request: policyContext.request,
                    effects: TerminalNotificationPolicyEffects(),
                    now: Date(),
                    cooldownReservation: cooldownReservation,
                    agentId: agentId,
                    workspaceTitle: workspaceTitle,
                    clickAction: clickAction
                )
                self.reportNotificationHookFailure(failure)
            }
        }
    }

    private struct NotificationCooldownReservation: Sendable {
        let key: String
        let previousDate: Date?
    }

    private struct NotificationPolicyContext: Sendable {
        let request: TerminalNotificationPolicyRequest
        let hooks: [CmuxResolvedNotificationHook]
        let globalConfigPath: String?
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
        body: String
    ) -> NotificationPolicyContext {
        let appDelegate = AppDelegate.shared
        let context = appDelegate?.contextContainingTabId(tabId)
        let tabManager = context?.tabManager ?? appDelegate?.tabManagerFor(tabId: tabId) ?? appDelegate?.tabManager
        let cmuxConfigStore = context?.cmuxConfigStore
        let workspace = tabManager?.tabs.first(where: { $0.id == tabId })
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

        return NotificationPolicyContext(
            request: TerminalNotificationPolicyRequest(
                tabId: tabId,
                surfaceId: surfaceId,
                panelId: panelId,
                title: title,
                subtitle: subtitle,
                body: body,
                cwd: cwd,
                isAppFocused: isAppFocused,
                isFocusedPanel: isFocusedPanel
            ),
            hooks: cmuxConfigStore?.notificationHooks(startingFrom: workspace?.isRemoteWorkspace == true ? nil : cwd) ?? [],
            globalConfigPath: cmuxConfigStore?.globalConfigPath
        )
    }

    private func applyNotification(
        request: TerminalNotificationPolicyRequest,
        envelope: TerminalNotificationPolicyEnvelope,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?,
        agentId: String?,
        workspaceTitle: String?,
        clickAction: TerminalNotificationClickAction?
    ) {
        let payload = envelope.notification
        // A notification hook that rewrote any text field owns the banner
        // verbatim: drop the workspace title so the workspace-aware agent
        // recomposition (which would demote a hook-provided title into the
        // subtitle) never overrides hook output. Untouched notifications keep
        // the composed banner.
        let hookModifiedText = payload.title != request.title
            || payload.subtitle != request.subtitle
            || payload.body != request.body
        applyNotification(
            request: TerminalNotificationPolicyRequest(
                tabId: request.tabId,
                surfaceId: request.surfaceId,
                panelId: request.panelId,
                title: payload.title,
                subtitle: payload.subtitle,
                body: payload.body,
                cwd: request.cwd,
                isAppFocused: request.isAppFocused,
                isFocusedPanel: request.isFocusedPanel
            ),
            effects: envelope.effects,
            now: now,
            cooldownReservation: cooldownReservation,
            agentId: agentId,
            workspaceTitle: hookModifiedText ? nil : workspaceTitle,
            clickAction: clickAction
        )
    }

    private func applyNotification(
        request: TerminalNotificationPolicyRequest,
        effects: TerminalNotificationPolicyEffects,
        now: Date,
        cooldownReservation: NotificationCooldownReservation?,
        agentId: String?,
        workspaceTitle: String?,
        clickAction: TerminalNotificationClickAction?
    ) {
        let shouldSuppressExternalDelivery = shouldSuppressExternalDelivery(
            tabId: request.tabId,
            surfaceId: request.surfaceId
        )
        let notification = TerminalNotification(
            id: UUID(),
            tabId: request.tabId,
            surfaceId: request.surfaceId,
            panelId: request.panelId,
            title: request.title,
            subtitle: request.subtitle,
            body: request.body,
            agentId: agentId,
            workspaceTitle: workspaceTitle,
            createdAt: now,
            isRead: !effects.markUnread,
            paneFlash: effects.paneFlash,
            clickAction: clickAction
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
        setWorkspaceManualUnread(false, forTabId: notification.tabId)
        notifications = updated
        commitCooldownReservation(cooldownReservation, at: now)
#if DEBUG
        cmuxDebugLog(
            "notification.store.record workspace=\(notification.tabId.uuidString.prefix(8)) surface=\(notification.surfaceId?.uuidString.prefix(8) ?? "nil") removed=\(idsToClear.count) unread=\(!notification.isRead ? 1 : 0) paneFlash=\(notification.paneFlash ? 1 : 0) suppressExternal=\(shouldSuppressExternalDelivery ? 1 : 0) total=\(notifications.count)"
        )
#endif
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
            // A newer notification for this tab+surface superseded the old one
            // and its Mac banner was just cleared. When a replacement banner
            // push is expected, DEFER the phone-banner dismiss until that push
            // is actually queued (see ``deliverNotificationSideEffects``): the
            // phone must never lose its only banner to a dismissal whose
            // replacement was throttled. When no replacement will be forwarded
            // (suppressed/focused, non-desktop effects, forwarding off, or the
            // `.onlyWhenAway` presence gate suppressing it while the Mac is
            // active), emit the dismiss immediately — nothing is coming to
            // replace the banner, and the Mac is not showing one either, so
            // deferring would just leave the stale banner stuck until a later
            // forward. Only the burst throttle is a legitimate defer-and-flush
            // case, which is why ``PhonePushClient/willForwardReplacement()``
            // mirrors the real send gate but ignores that throttle.
            let replacementWillForward = !shouldSuppressExternalDelivery
                && effects.desktop
                && PhonePushClient.shared.willForwardReplacement()
            if replacementWillForward {
                // The superseded entries already left the store; tombstone them
                // now so the reconcile sweep stays correct while the dismiss is
                // deferred.
                recordDismissTombstones(ids: idsToClear.compactMap { UUID(uuidString: $0) })
                supersededPhoneDismissBuffer.stash(
                    ids: idsToClear,
                    forKey: SupersededPhoneDismissBuffer.key(
                        tabId: notification.tabId,
                        surfaceId: notification.surfaceId
                    )
                )
            } else {
                // Also drain anything still parked for this key from an earlier
                // throttled supersede; this emit is its last guaranteed ride.
                emitNotificationsDismissed(
                    ids: idsToClear,
                    drainedSuperseded: supersededPhoneDismissBuffer.flush(
                        forKey: SupersededPhoneDismissBuffer.key(
                            tabId: notification.tabId,
                            surfaceId: notification.surfaceId
                        )
                    )
                )
            }
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
                // The phone push leaves the Mac entirely, so it must carry the
                // same scrubbed banner content as the desktop notification, not
                // the raw stored fields (which can still hold secrets/tokens
                // from a completion body assembled before the banner
                // materialization point).
                let banner = bannerContent(for: notification)
                let scrubbedNotification = TerminalNotification(
                    id: notification.id,
                    tabId: notification.tabId,
                    surfaceId: notification.surfaceId,
                    panelId: notification.panelId,
                    title: banner.title,
                    subtitle: banner.subtitle,
                    body: banner.body,
                    agentId: notification.agentId,
                    workspaceTitle: notification.workspaceTitle,
                    createdAt: notification.createdAt,
                    isRead: notification.isRead,
                    paneFlash: notification.paneFlash,
                    clickAction: notification.clickAction
                )
                let queued = PhonePushClient.shared.forward(scrubbedNotification, badgeCount: indexes.unreadCount)
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
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard !updated[index].isRead else { return }
        let supersededKey = SupersededPhoneDismissBuffer.key(
            tabId: updated[index].tabId,
            surfaceId: updated[index].surfaceId
        )
        updated[index].isRead = true
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
        emitNotificationsDismissed(
            ids: [id.uuidString],
            drainedSuperseded: supersededPhoneDismissBuffer.flush(forKey: supersededKey)
        )
    }

    func markUnread(id: UUID) {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard updated[index].isRead else { return }
        let tabId = updated[index].tabId
        updated[index].isRead = false
        notifications = updated
        // The notification itself now provides the workspace unread indicator. Clear any
        // existing manual or restored workspace unread state for the same tab so we don't
        // double-count it. (Mirrors what markLatestNotificationAsOldestUnread does for the
        // manual flag — restored hints are a one-time signal from a previous session and
        // should also defer to the concrete unread notification.)
        setWorkspaceManualUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
    }

    func markRead(forTabId tabId: UUID) {
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
        setWorkspaceManualUnread(false, forTabId: tabId)
        clearWorkspacePanelUnread(forTabId: tabId)
        setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
        setWorkspaceRestoredUnread(false, forTabId: tabId)
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            emitNotificationsDismissed(
                ids: idsToClear,
                drainedSuperseded: supersededPhoneDismissBuffer.flush(matchingTabId: tabId)
            )
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
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
        clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        if surfaceId == nil {
            clearWorkspacePanelUnread(forTabId: tabId)
            setPanelDerivedWorkspaceUnread(false, forTabId: tabId)
            setWorkspaceRestoredUnread(false, forTabId: tabId)
        }
        if !idsToClear.isEmpty {
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
        var updated = notifications
        guard let index = latestNotificationIndex(forTabId: tabId, surfaceId: surfaceId, in: updated) else {
            if surfaceId == nil, !workspaceIsUnread(forTabId: tabId) {
                setWorkspaceManualUnread(true, forTabId: tabId)
            }
            return nil
        }

        var notification = updated.remove(at: index)
        notification.isRead = false
        let insertionIndex = updated.lastIndex(where: { !$0.isRead }).map { $0 + 1 } ?? updated.endIndex
        updated.insert(notification, at: insertionIndex)
        setWorkspaceManualUnread(false, forTabId: tabId)
        notifications = updated
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
        clearAllWorkspacePanelUnread(forTabIds: tabIdsToClearPanelUnread)
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
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
        if let removed {
            clearFocusedReadIndicator(forTabId: removed.tabId, surfaceId: removed.surfaceId)
        }
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
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
        clearFocusedReadIndicator(forTabId: tabId)

        if didChangeNotifications, !removedIds.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: removedIds)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: removedIds)
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
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            agentId: notification.agentId,
            workspaceTitle: notification.workspaceTitle,
            createdAt: notification.createdAt,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            clickAction: notification.clickAction
        )
    }

    private func replaceNotificationsForClear(_ next: [TerminalNotification]) { suppressNotificationDiffPublishing = true; notifications = next; suppressNotificationDiffPublishing = false }

    func clearAll(discardQueuedNotifications: Bool = true) {
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotifications() }
        guard !notifications.isEmpty ||
            !focusedReadIndicatorByTabId.isEmpty ||
            !manualUnreadWorkspaceIds.isEmpty ||
            !panelDerivedUnreadWorkspaceIds.isEmpty ||
            !restoredUnreadWorkspaceIds.isEmpty else { return }
        let tabIdsToClearPanelUnread = panelDerivedUnreadWorkspaceIds.union(notifications.map(\.tabId))
        let ids = notifications.map { $0.id.uuidString }
        replaceNotificationsForClear([])
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
        discardQueuedNotifications: Bool = true
    ) {
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId, surfaceId: surfaceId) }
        let hadFocusedReadIndicator = focusedReadIndicatorByTabId[tabId].map { $0 == surfaceId } ?? false
        let hadRestoredWorkspaceUnread = surfaceId == nil && restoredUnreadWorkspaceIds.contains(tabId)
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        var supersededDrained = supersededPhoneDismissBuffer.flush(
            forKey: SupersededPhoneDismissBuffer.key(tabId: tabId, surfaceId: surfaceId)
        )
        for notification in notifications {
            if notification.matches(tabId: tabId, surfaceId: surfaceId) {
                idsToClear.append(notification.id.uuidString)
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
        guard !idsToClear.isEmpty || hadFocusedReadIndicator || hadRestoredWorkspaceUnread else { return }
        if !idsToClear.isEmpty {
            replaceNotificationsForClear(updated)
        }
        if surfaceId == nil {
            setWorkspaceRestoredUnread(false, forTabId: tabId)
        }
        clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        if !idsToClear.isEmpty {
            CmuxEventBus.shared.publishNotificationCleared(ids: idsToClear, workspaceId: tabId, surfaceId: surfaceId)
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
            emitNotificationsDismissed(ids: idsToClear, drainedSuperseded: supersededDrained)
        }
    }

    func rebindSurfaceNotifications(fromTabId sourceTabId: UUID, toTabId destinationTabId: UUID, surfaceId: UUID) {
        guard sourceTabId != destinationTabId else { return }
        TerminalMutationBus.shared.discardPendingNotifications(forTabId: sourceTabId, surfaceId: surfaceId)

        var didMoveNotification = false
        let updated = notifications.map { notification -> TerminalNotification in
            guard notification.matches(tabId: sourceTabId, surfaceId: surfaceId) else {
                return notification
            }
            didMoveNotification = true
            return TerminalNotification(
                id: notification.id,
                tabId: destinationTabId,
                surfaceId: notification.surfaceId,
                panelId: notification.panelId,
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body,
                agentId: notification.agentId,
                workspaceTitle: notification.workspaceTitle,
                createdAt: notification.createdAt,
                isRead: notification.isRead,
                paneFlash: notification.paneFlash,
                clickAction: notification.clickAction
            )
        }
        if didMoveNotification {
            notifications = updated
        }

        if focusedReadIndicatorByTabId[sourceTabId] == surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: sourceTabId)
            if focusedReadIndicatorByTabId[destinationTabId] == nil {
                focusedReadIndicatorByTabId[destinationTabId] = surfaceId
            }
        }
    }

    func clearNotifications(forTabId tabId: UUID, discardQueuedNotifications: Bool = true) {
        if discardQueuedNotifications { TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId) }
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
            CmuxEventBus.shared.publishNotificationCleared(ids: idsToClear, workspaceId: tabId, surfaceId: nil)
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
            emitNotificationsDismissed(
                ids: idsToClear,
                drainedSuperseded: supersededPhoneDismissBuffer.flush(matchingTabId: tabId)
            )
        }
    }

    private func scheduleUserNotification(
        _ notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        let banner = bannerContent(for: notification)
        guard effects.desktop else {
            playLocalNotificationFeedback(
                title: banner.title,
                subtitle: banner.subtitle,
                body: banner.body,
                effects: effects
            )
            return
        }

        let nativeDeliveryHooks = nativeNotificationDeliveryHooks
        let notificationTitle = banner.title
        let notificationSubtitle = banner.subtitle
        let notificationBody = banner.body
        let notificationId = notification.id
        let notificationTabId = notification.tabId
        let notificationSurfaceId = notification.surfaceId
        let clickActionUserInfo = notification.clickAction?.userInfo ?? [:]
        let categoryIdentifier = Self.categoryIdentifier

        let handleAuthorization: NativeNotificationDeliveryHooks.AuthorizationCompletion = { authorized, effectiveAuthorizationState in
            let content = UNMutableNotificationContent()
            content.title = notificationTitle
            content.subtitle = notificationSubtitle
            content.body = notificationBody
            guard authorized else {
                NativeNotificationDeliveryHooks.playNativeUnavailableFeedback(
                    effects: Self.fallbackEffects(effects, authorizationState: effectiveAuthorizationState)
                )
                return
            }
            content.sound = effects.sound ? NotificationSoundSettings.sound() : nil
            content.categoryIdentifier = categoryIdentifier
            content.userInfo = [
                "tabId": notificationTabId.uuidString,
                "notificationId": notificationId.uuidString,
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
                    NativeNotificationDeliveryHooks.playNativeUnavailableFeedback(effects: effects)
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
        let banner = bannerContent(for: notification)
        nativeNotificationDeliveryHooks.runLocalFeedback(
            title: banner.title,
            subtitle: banner.subtitle,
            body: banner.body,
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

    private static func notificationSortPrecedes(_ lhs: TerminalNotification, _ rhs: TerminalNotification) -> Bool {
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

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        TerminalMutationBus.shared.discardPendingNotifications()
        self.notifications = notifications
        clearWorkspaceManualUnread()
        clearPanelDerivedWorkspaceUnread()
        clearWorkspaceRestoredUnread()
        focusedReadIndicatorByTabId.removeAll()
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
