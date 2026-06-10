import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Notification popover, unread jumps, and notification configuration
extension AppDelegate {
    func toggleNotificationsPopover(animated: Bool = true, anchorView: NSView? = nil) {
        titlebarAccessoryController.toggleNotificationsPopover(animated: animated, anchorView: anchorView)
    }

    @discardableResult
    func dismissNotificationsPopoverIfShown() -> Bool {
        titlebarAccessoryController.dismissNotificationsPopoverIfShown()
    }

    func isNotificationsPopoverShown() -> Bool {
        titlebarAccessoryController.isNotificationsPopoverShown()
    }

    @discardableResult
    func jumpToLatestUnread(
        excludingNotificationId excludedNotificationId: UUID? = nil,
        excludingWorkspaceId excludedWorkspaceId: UUID? = nil
    ) -> TerminalNotification? {
        guard let notificationStore else { return nil }
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData([
                "jumpUnreadInvoked": "1",
                "jumpUnreadNotificationCount": String(notificationStore.notifications.count),
            ])
        }
#endif
        // Prefer the latest unread that we can actually open. In early startup (especially on the VM),
        // the window-context registry can lag behind model initialization, so fall back to whatever
        // tab manager currently owns the tab.
        for notification in notificationStore.notifications
            where Self.shouldOpenFromJumpToLatestUnread(
                notification,
                excludingNotificationId: excludedNotificationId,
                excludingWorkspaceId: excludedWorkspaceId
            ) {
            if openTerminalNotification(notification) {
                return notificationStore.notifications.first(where: { $0.id == notification.id }) ?? notification
            }
        }
        _ = openLatestWorkspaceUnread(excludingWorkspaceId: excludedWorkspaceId)
        return nil
    }

    static func shouldOpenFromJumpToLatestUnread(
        _ notification: TerminalNotification,
        excludingNotificationId excludedNotificationId: UUID? = nil,
        excludingWorkspaceId excludedWorkspaceId: UUID? = nil
    ) -> Bool {
        guard !notification.isRead, notification.id != excludedNotificationId else { return false }
        if let excludedWorkspaceId,
           notification.tabId == excludedWorkspaceId {
            return false
        }
        return notification.clickAction == nil
    }

    private func openLatestWorkspaceUnread(excludingWorkspaceId excludedWorkspaceId: UUID? = nil) -> Bool {
        guard let notificationStore else { return false }
        var unreadWorkspaceIds = notificationStore.workspaceUnreadIndicatorIds
        if let excludedWorkspaceId {
            unreadWorkspaceIds.remove(excludedWorkspaceId)
        }
        guard !unreadWorkspaceIds.isEmpty else { return false }

        var seenWindowIds = Set<UUID>()
        let preferredContext = preferredRegisteredMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)
        let orderedContexts = ([preferredContext].compactMap { $0 } + sortedMainWindowContextsForSessionSnapshot())
            .filter { seenWindowIds.insert($0.windowId).inserted }

        for context in orderedContexts {
            for workspace in context.tabManager.tabs where unreadWorkspaceIds.contains(workspace.id) {
                if openWorkspaceUnread(workspace, in: context) {
                    return true
                }
            }
        }

        guard let tabManager,
              let workspace = tabManager.tabs.first(where: { unreadWorkspaceIds.contains($0.id) }) else {
            return false
        }
        let panelId = workspace.preferredUnreadPanelIdForJump()
        let didOpen = openNotificationFallback(tabId: workspace.id, surfaceId: panelId, notificationId: nil)
        if didOpen {
            clearWorkspaceUnreadAfterJump(workspace: workspace, panelId: panelId)
        }
        return didOpen
    }

    private func openWorkspaceUnread(_ workspace: Workspace, in context: MainWindowContext) -> Bool {
        let panelId = workspace.preferredUnreadPanelIdForJump()
        let didOpen = openNotificationInContext(context, tabId: workspace.id, surfaceId: panelId, notificationId: nil)
        if didOpen {
            clearWorkspaceUnreadAfterJump(workspace: workspace, panelId: panelId)
        }
        return didOpen
    }

    private func clearWorkspaceUnreadAfterJump(workspace: Workspace, panelId: UUID?) {
        if let panelId,
           shouldTriggerManualUnreadJumpFlash(workspace: workspace, panelId: panelId) {
            workspace.triggerUnreadIndicatorDismissFlash(panelId: panelId)
        }
        workspace.clearUnreadAfterJump(panelId: panelId)
    }

    private func shouldTriggerManualUnreadJumpFlash(workspace: Workspace, panelId: UUID) -> Bool {
        workspace.manualUnreadPanelIds.contains(panelId) ||
            workspace.hasRestoredUnreadIndicator(panelId: panelId) ||
            (notificationStore?.hasManualUnread(forTabId: workspace.id) ?? false) ||
            (notificationStore?.hasRestoredUnreadIndicator(forTabId: workspace.id) ?? false)
    }

    @discardableResult
    func toggleFocusedNotificationUnread(
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        guard let notificationStore,
              let target = focusedNotificationTarget(preferredWindow: preferredWindow) else {
            return false
        }
        if let panelTarget = focusedPanelNotificationTarget(target) {
            let panelId = panelTarget.panelId
            let workspace = panelTarget.workspace
            let focusedPanelHasRestoredUnread = workspace.hasRestoredUnreadIndicator(panelId: panelId)
            let hasWorkspaceOnlyRestoredUnread =
                notificationStore.hasRestoredUnreadIndicator(forTabId: target.tabId) &&
                !focusedPanelHasRestoredUnread &&
                !workspace.hasWorkspaceContributingRestoredUnreadIndicator
            if notificationStore.hasVisibleNotificationIndicator(forTabId: target.tabId, surfaceId: nil) ||
                hasWorkspaceOnlyRestoredUnread {
                notificationStore.markRead(forTabId: target.tabId)
                return true
            }
            let hasWorkspaceManualUnreadOnPanel =
                notificationStore.hasManualUnread(forTabId: target.tabId) &&
                workspace.representativePanelIdForWorkspaceManualUnread() == panelId
            let isPanelUnread =
                workspace.manualUnreadPanelIds.contains(panelId) ||
                focusedPanelHasRestoredUnread ||
                notificationStore.hasVisibleNotificationIndicator(forTabId: target.tabId, surfaceId: panelId) ||
                hasWorkspaceManualUnreadOnPanel
            if isPanelUnread {
                workspace.markPanelRead(panelId)
                if hasWorkspaceManualUnreadOnPanel {
                    _ = notificationStore.clearManualUnread(forTabId: target.tabId)
                }
                return true
            }
            workspace.markPanelUnread(panelId)
            return true
        }
        if notificationStore.workspaceIsUnread(forTabId: target.tabId) {
            notificationStore.markRead(forTabId: target.tabId)
            return true
        }
        notificationStore.markUnread(forTabId: target.tabId)
        return true
    }

    @discardableResult
    func markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
        preferredWindow: NSWindow? = nil
    ) -> TerminalNotification? {
        guard let result = markFocusedNotificationAsOldestUnread(preferredWindow: preferredWindow) else {
            return nil
        }
        switch result {
        case .deferredNotification(let notificationId):
            return jumpToLatestUnread(excludingNotificationId: notificationId)
        case .markedWorkspaceWithoutNotification(let tabId):
            return jumpToLatestUnread(excludingWorkspaceId: tabId)
        }
    }

    private struct FocusedNotificationTarget {
        let tabId: UUID
        let surfaceId: UUID?
    }

    private struct FocusedPanelNotificationTarget {
        let workspace: Workspace
        let panelId: UUID
    }

    private enum FocusedNotificationMarkResult {
        case deferredNotification(UUID)
        case markedWorkspaceWithoutNotification(UUID)
    }

    private func focusedPanelNotificationTarget(_ target: FocusedNotificationTarget) -> FocusedPanelNotificationTarget? {
        guard let surfaceId = target.surfaceId,
              let workspace = workspaceForMainActor(tabId: target.tabId) else {
            return nil
        }
        let panelId: UUID?
        if workspace.panels[surfaceId] != nil {
            panelId = surfaceId
        } else {
            panelId = workspace.panelIdFromSurfaceId(TabID(uuid: surfaceId))
        }
        guard let panelId,
              workspace.panels[panelId] != nil else {
            return nil
        }
        return FocusedPanelNotificationTarget(workspace: workspace, panelId: panelId)
    }

    private func markFocusedNotificationAsOldestUnread(preferredWindow: NSWindow?) -> FocusedNotificationMarkResult? {
        guard let notificationStore,
              let target = focusedNotificationTarget(preferredWindow: preferredWindow) else {
            return nil
        }
        return markFocusedNotificationAsOldestUnread(target: target, notificationStore: notificationStore)
    }

    private func markFocusedNotificationAsOldestUnread(
        target: FocusedNotificationTarget,
        notificationStore: TerminalNotificationStore
    ) -> FocusedNotificationMarkResult? {
        if let notificationId = notificationStore.markLatestNotificationAsOldestUnread(
            forTabId: target.tabId,
            surfaceId: target.surfaceId
        ) {
            return .deferredNotification(notificationId)
        }
        if let panelTarget = focusedPanelNotificationTarget(target) {
            let workspace = panelTarget.workspace
            let panelId = panelTarget.panelId
            let panelAlreadyUnread =
                workspace.manualUnreadPanelIds.contains(panelId) ||
                workspace.hasRestoredUnreadIndicator(panelId: panelId) ||
                notificationStore.hasVisibleNotificationIndicator(forTabId: target.tabId, surfaceId: panelId)
            let hasWorkspaceOnlyRestoredUnread =
                notificationStore.hasRestoredUnreadIndicator(forTabId: target.tabId) &&
                !workspace.hasWorkspaceContributingRestoredUnreadIndicator
            if !panelAlreadyUnread &&
                !notificationStore.hasManualUnread(forTabId: target.tabId) &&
                !hasWorkspaceOnlyRestoredUnread {
                workspace.markPanelUnread(panelId)
            }
        } else if !notificationStore.workspaceIsUnread(forTabId: target.tabId) {
            notificationStore.markUnread(forTabId: target.tabId)
        }
        return .markedWorkspaceWithoutNotification(target.tabId)
    }

    private func focusedNotificationTarget(preferredWindow: NSWindow?) -> FocusedNotificationTarget? {
        if let terminalContext = focusedTerminalShortcutContext(preferredWindow: preferredWindow) {
            return FocusedNotificationTarget(tabId: terminalContext.workspaceId, surfaceId: terminalContext.panelId)
        }

        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let context = contextForMainWindow(targetWindow),
           let selectedTabId = context.tabManager.selectedTabId ?? context.tabManager.tabs.first?.id {
            return FocusedNotificationTarget(
                tabId: selectedTabId,
                surfaceId: context.tabManager.focusedSurfaceId(for: selectedTabId)
            )
        }

        if let activeManager = tabManager,
           let selectedTabId = activeManager.selectedTabId ?? activeManager.tabs.first?.id {
            return FocusedNotificationTarget(
                tabId: selectedTabId,
                surfaceId: activeManager.focusedSurfaceId(for: selectedTabId)
            )
        }

        return nil
    }

    func configureUserNotifications() {
        let actions = [
            UNNotificationAction(
                identifier: TerminalNotificationStore.actionShowIdentifier,
                title: "Show"
            )
        ]

        let category = UNNotificationCategory(
            identifier: TerminalNotificationStore.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Feed categories with inline decision buttons. Identifiers and
        // action strings are matched in `handleFeedNotificationResponse`.
        let permissionOnceAction = UNNotificationAction(
            identifier: "feed.permission.once",
            title: String(localized: "feed.notification.permission.allowOnce", defaultValue: "Allow Once")
        )
        let permissionAlwaysAction = UNNotificationAction(
            identifier: "feed.permission.always",
            title: String(localized: "feed.notification.permission.always", defaultValue: "Always")
        )
        let permissionAllAction = UNNotificationAction(
            identifier: "feed.permission.all",
            title: String(localized: "feed.notification.permission.all", defaultValue: "All tools")
        )
        let permissionDenyAction = UNNotificationAction(
            identifier: "feed.permission.deny",
            title: String(localized: "feed.notification.permission.deny", defaultValue: "Deny"),
            options: [.destructive]
        )
        let permissionCategories = Self.feedPermissionNotificationCategoryIds().map { categoryId in
            var actions: [UNNotificationAction] = []
            if categoryId.contains("Once") || categoryId == "CMUXFeedPermission" {
                actions.append(permissionOnceAction)
            }
            if categoryId.contains("Always") || categoryId == "CMUXFeedPermission" {
                actions.append(permissionAlwaysAction)
            }
            if categoryId.contains("All") {
                actions.append(permissionAllAction)
            }
            actions.append(permissionDenyAction)
            return UNNotificationCategory(
                identifier: categoryId,
                actions: actions,
                intentIdentifiers: [],
                options: []
            )
        }
        let exitPlanCategory = UNNotificationCategory(
            identifier: "CMUXFeedExitPlan",
            actions: [
                UNNotificationAction(
                    identifier: "feed.exit_plan.ultraplan",
                    title: String(localized: "feed.notification.exitPlan.ultraplan", defaultValue: "Ultraplan")
                ),
                UNNotificationAction(
                    identifier: "feed.exit_plan.manual",
                    title: String(localized: "feed.notification.exitPlan.manual", defaultValue: "Manual")
                ),
                UNNotificationAction(
                    identifier: "feed.exit_plan.autoAccept",
                    title: String(localized: "feed.notification.exitPlan.autoAccept", defaultValue: "Auto")
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
        let questionCategory = UNNotificationCategory(
            identifier: "CMUXFeedQuestion",
            actions: [
                UNNotificationAction(
                    identifier: "feed.question.open",
                    title: String(localized: "feed.notification.question.reply", defaultValue: "Reply"),
                    options: [.foreground]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(Set([category, exitPlanCategory, questionCategory] + permissionCategories))
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(response)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        if handleFeedNotificationResponse(response) {
            return
        }
        guard let tabIdString = response.notification.request.content.userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString) else {
            return
        }
        let surfaceId: UUID? = {
            guard let surfaceIdString = response.notification.request.content.userInfo["surfaceId"] as? String else {
                return nil
            }
            return UUID(uuidString: surfaceIdString)
        }()

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, TerminalNotificationStore.actionShowIdentifier:
            let notificationId: UUID? = {
                if let id = UUID(uuidString: response.notification.request.identifier) {
                    return id
                }
                if let idString = response.notification.request.content.userInfo["notificationId"] as? String,
                   let id = UUID(uuidString: idString) {
                    return id
                }
                return nil
            }()
            if let clickAction = TerminalNotificationClickAction(userInfo: response.notification.request.content.userInfo) {
                Task { @MainActor in
                    let didPerform = self.performTerminalNotificationClickAction(clickAction)
                    if didPerform, let notificationId {
                        self.notificationStore?.markRead(id: notificationId)
                    }
                }
                return
            }
            DispatchQueue.main.async {
                _ = self.openNotification(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
            }
        case UNNotificationDismissActionIdentifier:
            DispatchQueue.main.async {
                if let notificationId = UUID(uuidString: response.notification.request.identifier) {
                    self.notificationStore?.markRead(id: notificationId)
                } else if let notificationIdString = response.notification.request.content.userInfo["notificationId"] as? String,
                          let notificationId = UUID(uuidString: notificationIdString) {
                    self.notificationStore?.markRead(id: notificationId)
                }
            }
        default:
            break
        }
    }

}
