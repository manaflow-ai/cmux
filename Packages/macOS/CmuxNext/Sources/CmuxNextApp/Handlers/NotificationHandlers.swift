import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

/// Notification actions over the daemon's retained unread markers
/// (`TabModel.notification`) and `ack-tab-notifications`
/// (notification-ack-v1), and the notifications panel over the ledger
/// (`list-notifications`, `notification.clear`). Marking unread marks the
/// tab itself (``TabUnreadMark``, `tab-mark-unread-v1`): a notification is
/// never made unread again. The row verbs act on the panel row their
/// `notification` argument names, else on the latest unread.
enum NotificationHandlers {
    static let ack = DaemonCapability.notificationAck.rawValue

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let panel = NotificationsPanelController(context: context)
        registry.bind("showNotifications", run: { _ in panel.toggle() })
        let feedPanel = FeedPanelController(context: context)
        registry.bind("feed.show", run: { _ in feedPanel.toggle() })
        services.pages.register(services.feedPage)
        registry.bind("clearAllNotifications", requires: ack, daemon: context.daemon, run: { _ in
            _ = try context.requireConnection()
            context.daemon.send("notification.clear") { connection in
                try await connection.clearNotifications()
                await MainActor.run { panel.reload() }
            }
        })
        registry.bind("jumpToUnread", run: { _ in try open(latestUnread(context), context) })
        // The live tab whose agent was prompted last (a closed one is no longer in the tree),
        // shown as a user jump: its window comes forward and its pane takes focus.
        registry.bind("jumpToLastPrompt", run: { _ in
            _ = try context.requireConnection()
            let store = context.daemon.store
            let prompted = context.allTabs.compactMap { located in store.agents.lastPromptBySurface[located.tab.surface].map { (located, $0) } }
            guard let last = prompted.max(by: { $0.1 < $1.1 })?.0 else { throw ActionFailure(message: MiscHandlerStrings.noPrompt) }
            guard ActionRunScope.viewChangeAllowed() else { return }
            context.services.revealTab(last.tab.id)
        })
        registry.bind("markOldestUnreadAndJumpNext", requires: ack, daemon: context.daemon, run: { _ in
            let tabs = unread(context)
            guard let oldest = tabs.first else { throw ActionFailure(message: MiscHandlerStrings.noUnread) }
            try acknowledge([oldest.tab.surface], context)
            if tabs.count > 1 { try open(tabs[1], context) }
        })
        registry.bind("markAllNotificationsRead", requires: ack, daemon: context.daemon, run: { _ in
            let tabs = unread(context)
            guard !tabs.isEmpty else { throw ActionFailure(message: MiscHandlerStrings.noUnread) }
            try acknowledge(tabs.map(\.tab.surface), context)
        })
        // Mark Tab Read/Unread: reads an unread tab, else marks it unread (any tab, no notification needed).
        registry.bind("toggleUnread", run: { invocation in
            guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id) else {
                throw ActionFailure(message: MiscHandlerStrings.noPane)
            }
            try TabUnreadMark.toggle(tab, pane: pane.pane, context: context)
        })
        registry.bind("notificationOpen", run: { invocation in
            guard let row = try panel.row(invocation) else { return try open(latestUnread(context), context) }
            guard let surface = row.surface, let located = context.services.notifications.locate(surface: surface, in: context.daemon.store) else {
                throw ActionFailure(message: NotificationsPanelStrings.sourceClosed)
            }
            try open(located, context)
            panel.close()
        })
        registry.bind("notificationToggleRead", requires: ack, daemon: context.daemon, run: { invocation in
            if let row = try panel.row(invocation) {
                guard let surface = row.surface else { throw ActionFailure(message: NotificationsPanelStrings.sourceClosed) }
                if row.unread { return try acknowledge([surface], context) }
                // A read row: Mark Unread marks its tab unread (the notification stays read).
                guard let located = context.services.notifications.locate(surface: surface, in: context.daemon.store) else {
                    throw ActionFailure(message: NotificationsPanelStrings.sourceClosed)
                }
                return try TabUnreadMark.set(true, tab: located.tab, daemon: context.services.daemon(for: located.pane))
            }
            guard let latest = unread(context).last else { throw ActionFailure(message: MiscHandlerStrings.noUnread) }
            try acknowledge([latest.tab.surface], context)
        })
        registry.bind("notificationDismiss", requires: ack, daemon: context.daemon, run: { invocation in
            guard let row = try panel.row(invocation) else { return try acknowledge([latestUnread(context).tab.surface], context) }
            try dismiss(row, panel: panel, context)
        })
        registry.bind("notificationCopy", requires: ack, daemon: context.daemon, run: { invocation in
            _ = try context.requireConnection()
            if let row = try panel.row(invocation) { return context.copy(row.copyText) }
            // An empty ledger is refused: the CLI awaits the reason, a palette or key run shows it.
            let awaited = registry.isCapturingWork, none = MiscHandlerStrings.noNotificationToCopy
            context.daemon.send("copy-notification", onFailure: { [weak registry] failure in
                if !awaited { registry?.refuse(failure.message) }
            }) { connection in
                guard let entry = try await connection.notificationLedger(limit: 1).first else {
                    throw ActionFailure.invalidTarget(none)
                }
                let text = entry.body.isEmpty ? entry.title : "\(entry.title)\n\(entry.body)"
                await MainActor.run { context.copy(text) }
            }
        })
        NotificationSettingsHandlers.bind(into: registry, context: context)
        AgentChatMuteHandlers.bind(into: registry, context: context)
        SubagentLimitHandlers.bind(into: registry, context: context)
        AgentChatIdentifierHandlers.bind(into: registry, context: context)
        // View Chat Only (`cmux agent view <chat>`, the palette): the All chats row's View Only opener.
        registry.bind("agentChat.view", run: { invocation in
            let key = (invocation["key"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard ChatOpenSubject.isWatchable(key: key) else { throw ActionFailure(message: RefusalStrings.notAWatchableChat(key)) }
            context.services.chatsOpener.open(key, watch: true)
        })
    }

    /// Removes a panel row. The daemon clears by terminal, so this removes
    /// every notification of the row's terminal; a row without one is only
    /// marked read.
    static func dismiss(_ row: NotificationsPanelRow, panel: NotificationsPanelController, _ context: AppActionContext) throws {
        _ = try context.requireConnection()
        guard let terminal = row.terminal else {
            guard let surface = row.surface else { throw ActionFailure(message: NotificationsPanelStrings.sourceClosed) }
            return try acknowledge([surface], context)
        }
        context.daemon.send("notification.clear") { connection in
            try await connection.clearNotifications(terminal: terminal)
            await MainActor.run { panel.reload() }
        }
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

    /// A dismiss verb: acknowledges at once on the context's daemon (and withdraws this Mac's banners).
    static func acknowledge(_ surfaces: [SurfaceID], _ context: AppActionContext) throws {
        _ = try context.requireConnection()
        for tab in surfaces.compactMap(context.daemon.store.tab(surface:)) {
            context.services.notifications.acknowledge(tab, owner: context.daemon)
        }
    }
}
