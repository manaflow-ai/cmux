import AppKit
import Foundation
import Observation
import os
import UserNotifications
import Bonsplit

nonisolated let terminalNotificationLogger = Logger(
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

enum NotificationAuthorizationState: Equatable {
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

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let panelId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
    var paneFlash: Bool = true
    var clickAction: TerminalNotificationClickAction?

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool,
        paneFlash: Bool = true,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.clickAction = clickAction
    }

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }
}

@MainActor
@Observable
final class TerminalNotificationStore {
    struct TabSurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    struct NotificationIndexes {
        var unreadCount = 0
        var unreadCountByTabId: [UUID: Int] = [:]
        var unreadByTabSurface = Set<TabSurfaceKey>()
        var latestUnreadByTabId: [UUID: TerminalNotification] = [:]
        var latestByTabId: [UUID: TerminalNotification] = [:]
    }

    static let shared = TerminalNotificationStore()

    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"
    enum AuthorizationRequestOrigin: String {
        case notificationDelivery = "notification_delivery"
        case settingsButton = "settings_button"
        case settingsTest = "settings_test"
    }

    var notifications: [TerminalNotification] = [] {
        didSet {
            indexes = Self.buildIndexes(for: notifications)
            refreshUnreadPresentation()
            if !suppressNotificationDiffPublishing { CmuxEventBus.shared.publishNotificationChanges(oldValue: oldValue, newValue: notifications) }
        }
    }
    var notificationMenuSnapshot = NotificationMenuSnapshotBuilder.make(notifications: []) {
        didSet {
            let snapshot = notificationMenuSnapshot
            for continuation in menuSnapshotContinuations.values {
                continuation.yield(snapshot)
            }
        }
    }
    // Workspace-level unread drives sidebar workspace badges; pane-level manual
    // unread remains owned by Workspace.manualUnreadPanelIds.
    var manualUnreadWorkspaceIds: Set<UUID> = [] {
        didSet { refreshUnreadPresentation() }
    }
    var panelDerivedUnreadWorkspaceIds: Set<UUID> = [] {
        didSet { refreshUnreadPresentation() }
    }
    var restoredUnreadWorkspaceIds: Set<UUID> = [] {
        didSet { refreshUnreadPresentation() }
    }
    var focusedReadIndicatorByTabId: [UUID: UUID] = [:]
    var authorizationState: NotificationAuthorizationState = .unknown
    @ObservationIgnored var suppressNotificationDiffPublishing = false

    /// Live `notificationMenuSnapshot` consumers (replacement for the former
    /// `$notificationMenuSnapshot` Combine projection), keyed per subscription.
    @ObservationIgnored private var menuSnapshotContinuations: [UUID: AsyncStream<NotificationMenuSnapshot>.Continuation] = [:]

    /// Async replacement for the former `$notificationMenuSnapshot` Combine
    /// projection. Mirrors `@Published`'s CurrentValueSubject-like semantics:
    /// the current snapshot is emitted at subscription time, followed by every
    /// subsequent change (delivered after the property is set, like the old
    /// `.receive(on: DispatchQueue.main)` hop).
    func notificationMenuSnapshotUpdates() -> AsyncStream<NotificationMenuSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: NotificationMenuSnapshot.self)
        menuSnapshotContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.menuSnapshotContinuations.removeValue(forKey: id)
            }
        }
        continuation.yield(notificationMenuSnapshot)
        return stream
    }

    let center = UNUserNotificationCenter.current()
    @ObservationIgnored var hasRequestedAutomaticAuthorization = false
    @ObservationIgnored var hasDeferredAuthorizationRequest = false
    @ObservationIgnored var hasPromptedForSettings = false
    @ObservationIgnored private var userDefaultsObserver: NSObjectProtocol?
    let settingsPromptWindowRetryDelay: TimeInterval = 0.5
    let settingsPromptWindowRetryLimit = 20
    @ObservationIgnored var notificationSettingsWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    @ObservationIgnored var notificationSettingsAlertFactory: () -> NSAlert = {
        NSAlert()
    }
    @ObservationIgnored var notificationSettingsScheduler: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void = {
        delay,
        block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }
    @ObservationIgnored var notificationSettingsURLOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    @ObservationIgnored var notificationDeliveryHandler: (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void = {
        store,
        notification,
        effects in
        store.scheduleUserNotification(notification, effects: effects)
    }
    @ObservationIgnored var suppressedNotificationFeedbackHandler: (TerminalNotificationStore, TerminalNotification, TerminalNotificationPolicyEffects) -> Void = {
        store,
        notification,
        effects in
        store.playSuppressedNotificationFeedback(for: notification, effects: effects)
    }
    struct NotificationHookFailureThrottleKey: Hashable {
        let hookId: String
        let sourcePath: String?
    }

    static let notificationHookFailureThrottle: TimeInterval = 300
    @ObservationIgnored var lastNotificationDateByCooldownKey: [String: Date] = [:]
    @ObservationIgnored var lastNotificationHookFailureDateByKey: [NotificationHookFailureThrottleKey: Date] = [:]
    // Tracked on purpose: views read derived state (`unreadCount`,
    // `hasUnreadNotification(forTabId:surfaceId:)`, ...) that is computed from
    // `indexes`, and `indexes` is rebuilt in `notifications.didSet`.
    var indexes = NotificationIndexes()

    private init() {
        indexes = Self.buildIndexes(for: notifications)
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDockBadge()
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

    func refreshDockBadge() {
        let label = Self.dockBadgeLabel(
            unreadCount: unreadCount,
            isEnabled: NotificationBadgeSettings.isDockBadgeEnabled(),
            runTag: TaggedRunBadgeSettings.normalizedTag()
        )
        NSApp?.dockTile.badgeLabel = label
    }
}
