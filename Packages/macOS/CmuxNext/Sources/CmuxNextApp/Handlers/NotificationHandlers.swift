import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Notification actions over the daemon's retained unread markers
/// (`TabModel.notification`) and `ack-tab-notifications`
/// (notification-ack-v1). Acknowledging is the daemon's only transition, so
/// "mark unread" and "clear ledger" are refused or unavailable.
enum NotificationHandlers {
    static let ack = DaemonCapabilities.notificationAck

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let daemon = context.daemon
        registry.bind("jumpToUnread", run: { _ in try open(latestUnread(context), context) })
        registry.bind("markOldestUnreadAndJumpNext", requires: ack, daemon: daemon, run: { _ in
            let tabs = unread(context)
            guard let oldest = tabs.first else { throw ActionFailure(message: MiscHandlerStrings.noUnread) }
            try acknowledge([oldest.tab.surface], context)
            if tabs.count > 1 { try open(tabs[1], context) }
        })
        registry.bind("markAllNotificationsRead", requires: ack, daemon: daemon, run: { _ in
            let tabs = unread(context)
            guard !tabs.isEmpty else { throw ActionFailure(message: MiscHandlerStrings.noUnread) }
            try acknowledge(tabs.map(\.tab.surface), context)
        })
        registry.bind("toggleUnread", requires: ack, daemon: daemon, run: { invocation in
            guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id) else {
                throw ActionFailure(message: MiscHandlerStrings.noPane)
            }
            guard tab.hasUnread else { throw ActionFailure(message: MiscHandlerStrings.markUnread) }
            try acknowledge([tab.surface], context)
        })
        // Per-notification verbs act on the latest unread notification until
        // the notifications panel passes a notification target.
        registry.bind("notificationOpen", run: { _ in try open(latestUnread(context), context) })
        registry.bind("notificationToggleRead", requires: ack, daemon: daemon, run: { _ in
            guard let latest = unread(context).last else { throw ActionFailure(message: MiscHandlerStrings.markUnread) }
            try acknowledge([latest.tab.surface], context)
        })
        registry.bind("notificationDismiss", requires: ack, daemon: daemon, run: { _ in
            try acknowledge([latestUnread(context).tab.surface], context)
        })
        registry.bind("notificationCopy", requires: ack, daemon: daemon, run: { _ in
            _ = try context.requireConnection()
            context.daemon.send("copy-notification") { connection in
                guard let entry = try await connection.notificationLedger(limit: 1).first else { return }
                let text = entry.body.isEmpty ? entry.title : "\(entry.title)\n\(entry.body)"
                await MainActor.run { context.copy(text) }
            }
        })
        NotificationSettingsHandlers.bind(into: registry, context: context)
        registry.bindUnavailable(["showNotifications"], ActionFailure(message: MiscHandlerStrings.notificationsPanel))
        registry.bindUnavailable(["clearAllNotifications"], ActionFailure(message: MiscHandlerStrings.clearLedger))
    }

    /// Tabs with an unread marker, oldest first (by notification time, then
    /// tree order for markers without one).
    static func unread(_ context: AppActionContext) -> [LocatedTab] {
        context.allTabs.enumerated()
            .filter { $0.element.tab.hasUnread }
            .sorted { lhs, rhs in
                let left = lhs.element.tab.notification?.createdAtMs ?? 0
                let right = rhs.element.tab.notification?.createdAtMs ?? 0
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    static func latestUnread(_ context: AppActionContext) throws -> LocatedTab {
        guard let latest = unread(context).last else { throw ActionFailure(message: MiscHandlerStrings.noUnread) }
        return latest
    }

    /// Shows the tab and opens its notification: it is read unless
    /// `notifications.dismissal` is `never`. On daemons without
    /// notification-ack-v1 the reveal still happens.
    static func open(_ located: LocatedTab, _ context: AppActionContext) throws {
        _ = try context.requireConnection()
        context.reveal(located)
        if context.daemon.supports(ack) { context.services.notifications.opened(located.tab) }
    }

    /// A dismiss verb: acknowledges at once (and withdraws banners).
    static func acknowledge(_ surfaces: [SurfaceID], _ context: AppActionContext) throws {
        _ = try context.requireConnection()
        let store = context.daemon.store
        let notifications = context.services.notifications
        var remote: [SurfaceID] = []
        for surface in surfaces {
            if context.daemon === context.services.daemon, let tab = store.tab(surface: surface) {
                notifications.acknowledge(tab)
            } else {
                remote.append(surface)
            }
        }
        guard !remote.isEmpty else { return }
        let pending = remote
        context.daemon.send("ack-tab-notifications") { connection in
            for surface in pending { _ = try await connection.acknowledgeNotifications(of: surface) }
        }
    }
}
