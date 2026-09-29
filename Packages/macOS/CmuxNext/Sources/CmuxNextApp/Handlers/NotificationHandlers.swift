import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Notification actions over the daemon's retained unread markers
/// (`TabModel.notification`) and `ack-tab-notifications`
/// (notification-ack-v1). Acknowledging is the daemon's only transition, so
/// "mark unread" and "clear ledger" report typed failures.
enum NotificationHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("jumpToUnread") {
            guard let latest = unread(context).last else { return context.fail(HandlerStrings.noUnread) }
            open(latest, context)
        }
        registry.bind("markOldestUnreadAndJumpNext") {
            let tabs = unread(context)
            guard let oldest = tabs.first else { return context.fail(HandlerStrings.noUnread) }
            acknowledge([oldest.tab.surface], context)
            if tabs.count > 1 { open(tabs[1], context) }
        }
        registry.bind("markAllNotificationsRead") {
            let tabs = unread(context)
            guard !tabs.isEmpty else { return context.fail(HandlerStrings.noUnread) }
            acknowledge(tabs.map(\.tab.surface), context)
        }
        registry.bind("toggleUnread", invoke: { invocation in
            guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id) else {
                return context.fail(HandlerStrings.noPane)
            }
            guard tab.hasUnread else { return context.fail(HandlerStrings.markUnread) }
            acknowledge([tab.surface], context)
        })
        // Per-notification verbs act on the latest unread notification until
        // the notifications panel passes a notification target.
        registry.bind("notificationOpen") {
            guard let latest = unread(context).last else { return context.fail(HandlerStrings.noUnread) }
            open(latest, context)
        }
        registry.bind("notificationToggleRead") {
            guard let latest = unread(context).last else { return context.fail(HandlerStrings.markUnread) }
            acknowledge([latest.tab.surface], context)
        }
        registry.bind("notificationDismiss") {
            guard let latest = unread(context).last else { return context.fail(HandlerStrings.noUnread) }
            acknowledge([latest.tab.surface], context)
        }
        registry.bind("notificationCopy") {
            guard context.connection() != nil, supportsAck(context) else { return }
            context.daemon.send("copy-notification") { connection in
                guard let entry = try await connection.notificationLedger(limit: 1).first else { return }
                let text = entry.body.isEmpty ? entry.title : "\(entry.title)\n\(entry.body)"
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
        context.unavailable(["showNotifications"], HandlerStrings.notificationsPanel)
        context.unavailable(["clearAllNotifications"], HandlerStrings.clearLedger)
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

    /// Shows the tab and acknowledges its notification: focusing it reads it.
    /// On daemons without notification-ack-v1 the reveal still happens.
    static func open(_ located: LocatedTab, _ context: AppActionContext) {
        guard context.connection() != nil else { return }
        context.reveal(tab: located.tab, pane: located.pane, workspace: located.workspace)
        if context.daemon.supports(DaemonCapabilities.notificationAck) { acknowledge([located.tab.surface], context) }
    }

    /// Whether the daemon can acknowledge and list notifications; reports a
    /// failure when it cannot.
    static func supportsAck(_ context: AppActionContext) -> Bool {
        guard context.daemon.supports(DaemonCapabilities.notificationAck) else {
            context.fail(HandlerStrings.notificationAck)
            return false
        }
        return true
    }

    static func acknowledge(_ surfaces: [SurfaceID], _ context: AppActionContext) {
        guard context.connection() != nil, supportsAck(context) else { return }
        context.daemon.send("ack-tab-notifications") { connection in
            for surface in surfaces { _ = try await connection.acknowledgeNotifications(of: surface) }
        }
    }
}
