import AppKit
import CmuxNotifications
import Foundation

/// App-side adapters that let `AppDelegate` satisfy the `CmuxNotifications`
/// navigation seams the `NotificationNavigationCoordinator` depends on. Each
/// method body is the original `AppDelegate` resolver/mutator (lifted out of the
/// jump/open cluster), now reached through a protocol so the coordinator never
/// touches `TabManager`, `Workspace`, `MainWindowContext`, or `NSWindow`.
///
/// Legal per CONVENTIONS §6: these extend the app-owned `AppDelegate`, keeping
/// the window mechanics, `#if DEBUG` UI-test recorders, and Combine app-side
/// while the orchestration moves into the package.
extension AppDelegate: NotificationNavigationStoreReading {
    var orderedNotifications: [NotificationNavSnapshot] {
        guard let notificationStore else { return [] }
        return notificationStore.notifications.map { notification in
            NotificationNavSnapshot(
                id: notification.id,
                tabId: notification.tabId,
                surfaceId: notification.surfaceId,
                isRead: notification.isRead,
                clickAction: notification.clickAction.map(Self.navClickAction)
            )
        }
    }

    var workspaceUnreadIndicatorIds: Set<UUID> {
        notificationStore?.workspaceUnreadIndicatorIds ?? []
    }

    func hasManualUnread(forTabId tabId: UUID) -> Bool {
        notificationStore?.hasManualUnread(forTabId: tabId) ?? false
    }

    func hasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool {
        notificationStore?.hasRestoredUnreadIndicator(forTabId: tabId) ?? false
    }

    func markRead(id: UUID) {
        notificationStore?.markRead(id: id)
    }

    /// Maps the app-target click action onto the package's value-typed action.
    static func navClickAction(
        _ action: TerminalNotificationClickAction
    ) -> NotificationNavClickAction {
        switch action {
        case .revealInFinder(let path):
            return .revealInFinder(path: path)
        }
    }

    /// Whether `notification` is openable by the jump-to-latest scan. A thin
    /// shim over `NotificationNavSnapshot.isOpenableForJump`, kept so the legacy
    /// predicate name and its unit test remain valid (and prove the package
    /// predicate matches the original contract). The coordinator itself uses the
    /// snapshot predicate directly; this is not on its hot path.
    static func shouldOpenFromJumpToLatestUnread(
        _ notification: TerminalNotification,
        excludingNotificationId excludedNotificationId: UUID? = nil,
        excludingWorkspaceId excludedWorkspaceId: UUID? = nil
    ) -> Bool {
        NotificationNavSnapshot(
            id: notification.id,
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            isRead: notification.isRead,
            clickAction: notification.clickAction.map(navClickAction)
        )
        .isOpenableForJump(
            excludingNotificationId: excludedNotificationId,
            excludingWorkspaceId: excludedWorkspaceId
        )
    }
}

extension AppDelegate: MainWindowContextResolving {
    var orderedTargetsForUnreadJump: [MainWindowTarget] {
        // Mirrors the ordering `openLatestWorkspaceUnread` built inline: the
        // preferred registered context (from the key/main window) first, then
        // the session-snapshot ordering, de-duplicated by window id.
        var seenWindowIds = Set<UUID>()
        let preferredContext = preferredRegisteredMainWindowContext(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
        let orderedContexts = ([preferredContext].compactMap { $0 }
            + sortedMainWindowContextsForSessionSnapshot())
            .filter { seenWindowIds.insert($0.windowId).inserted }
        return orderedContexts.map { context in
            MainWindowTarget(
                windowId: context.windowId,
                workspaceIds: context.tabManager.tabs.map(\.id)
            )
        }
    }
}

extension AppDelegate: UnreadWorkspaceTargeting {
    func preferredUnreadPanelIdForJump(workspaceId: UUID) -> UUID? {
        workspaceFor(tabId: workspaceId)?.preferredUnreadPanelIdForJump()
    }

    func shouldTriggerManualUnreadJumpFlash(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let workspace = workspaceFor(tabId: workspaceId) else { return false }
        return workspace.manualUnreadPanelIds.contains(panelId) ||
            workspace.hasRestoredUnreadIndicator(panelId: panelId) ||
            (notificationStore?.hasManualUnread(forTabId: workspaceId) ?? false) ||
            (notificationStore?.hasRestoredUnreadIndicator(forTabId: workspaceId) ?? false)
    }

    func triggerUnreadIndicatorDismissFlash(workspaceId: UUID, panelId: UUID) {
        workspaceFor(tabId: workspaceId)?.triggerUnreadIndicatorDismissFlash(panelId: panelId)
    }

    func clearUnreadAfterJump(workspaceId: UUID, panelId: UUID?) {
        workspaceFor(tabId: workspaceId)?.clearUnreadAfterJump(panelId: panelId)
    }
}

extension AppDelegate: NotificationOpenRouting {
    func openRouted(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        openNotification(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
    }

    func openInWindow(windowId: UUID, tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else {
            return false
        }
        // openNotificationInContext takes the nested MainWindowContext directly.
        return openNotificationInContext(
            context,
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId
        )
    }

    func openInActiveWindowFallback(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        openNotificationFallback(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
    }

    func tabTitle(forTabId tabId: UUID) -> String? {
        tabTitle(for: tabId)
    }
}

extension AppDelegate: NotificationClickRouting {
    func perform(_ action: NotificationNavClickAction) -> Bool {
        switch action {
        case .revealInFinder(let path):
            return performTerminalNotificationClickAction(.revealInFinder(path: path))
        }
    }
}
