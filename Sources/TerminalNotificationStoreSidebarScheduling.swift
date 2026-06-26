import Foundation
import CmuxSettings

extension TerminalNotificationStore {
    func reorderWorkspaceForEffectsOnlyNotificationIfNeeded(
        _ notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        guard effects.reorderWorkspace,
              UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.reorderOnNotification) else {
            return
        }
        AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
            .moveTabToTopForNotification(notification.tabId)
    }

    func reorderWorkspacesByNotificationUrgencyIfNeeded(
        _ notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects,
        now: Date
    ) {
        let reorderSetting = UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.reorderOnNotification)
        guard effects.reorderWorkspace, reorderSetting else {
#if DEBUG
            cmuxDebugLog(
                "notification.scheduler.skip workspace=\(notification.tabId.uuidString.prefix(8)) effectsReorder=\(effects.reorderWorkspace ? 1 : 0) setting=\(reorderSetting ? 1 : 0)"
            )
#endif
            return
        }
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: notification.tabId) else {
#if DEBUG
            cmuxDebugLog("notification.scheduler.skip workspace=\(notification.tabId.uuidString.prefix(8)) reason=missingTabManager")
#endif
            return
        }
        let schedulerMode = UserDefaultsSettingsClient(defaults: .standard).value(
            for: SettingCatalog().sidebar.notificationSchedulerMode
        )
        let tabManagerId = ObjectIdentifier(tabManager)
        let snapshots = tabManager.tabs.enumerated().map { index, workspace in
            notificationSchedulerSnapshot(for: workspace, index: index)
        }
        let orderedWorkspaceIds = SidebarNotificationUrgencyScheduler.orderedWorkspaceIds(
            snapshots: snapshots,
            now: now,
            mode: schedulerMode,
            roundRobinCursor: sidebarSchedulerRoundRobinCursorByTabManagerId[tabManagerId]
        )
        if schedulerMode == .roundRobin,
           let nextCursor = orderedWorkspaceIds.first {
            sidebarSchedulerRoundRobinCursorByTabManagerId[tabManagerId] = nextCursor
        }
#if DEBUG
        let orderedWorkspaceLog = orderedWorkspaceIds
            .map { String($0.uuidString.prefix(8)) }
            .joined(separator: ",")
        cmuxDebugLog(
            "notification.scheduler.order workspace=\(notification.tabId.uuidString.prefix(8)) mode=\(schedulerMode.rawValue) ordered=\(orderedWorkspaceLog)"
        )
#endif
        guard orderedWorkspaceIds.contains(notification.tabId) else {
            tabManager.moveTabToTopForNotification(notification.tabId)
            return
        }
        tabManager.moveTabsToTopForNotificationPriority(orderedWorkspaceIds)
    }

    private func notificationSchedulerSnapshot(
        for workspace: Workspace,
        index: Int
    ) -> SidebarNotificationSchedulerSnapshot {
        let summary = sidebarUnread.summary(forWorkspaceId: workspace.id)
        return SidebarNotificationSchedulerSnapshot(
            workspaceId: workspace.id,
            originalIndex: index,
            unreadCount: summary.unreadCount,
            latestNotificationText: summary.latestNotificationText,
            latestNotificationCreatedAt: summary.latestNotificationCreatedAt,
            latestNotificationIsUnread: summary.latestNotificationIsUnread,
            workspaceTitle: workspace.customTitle ?? workspace.title,
            customDescription: workspace.customDescription,
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            remoteDisplayTarget: workspace.remoteDisplayTarget,
            remoteConnectionState: workspace.remoteConnectionState.rawValue,
            panelCount: workspace.panelDirectories.count
        )
    }
}
