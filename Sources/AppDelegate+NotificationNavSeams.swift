import AppKit
import Bonsplit
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

    var activeWorkspaceIdsForUnreadJump: [UUID] {
        // The active (global) tab manager, independent of the window-context
        // registry. Mirrors the legacy `self.tabManager.tabs` fallback so an
        // unread workspace is still resolvable during early startup / VM timing
        // before any main window registers.
        tabManager?.tabs.map(\.id) ?? []
    }
}

extension AppDelegate: UnreadWorkspaceTargeting {
    /// Resolves a workspace for unread-jump operations, falling back to the
    /// active tab manager when the window-context registry has not populated yet
    /// (early startup / VM timing). `workspaceFor(tabId:)` only consults
    /// registered/recoverable routes, so without this fallback the panel
    /// resolution and unread-clear would no-op for exactly the ids that
    /// `activeWorkspaceIdsForUnreadJump` supplies. Mirrors the legacy fallback,
    /// which operated on the concrete `tabManager.tabs` workspace directly.
    private func unreadJumpWorkspace(forTabId tabId: UUID) -> Workspace? {
        workspaceFor(tabId: tabId) ?? tabManager?.tabs.first(where: { $0.id == tabId })
    }

    func preferredUnreadPanelIdForJump(workspaceId: UUID) -> UUID? {
        unreadJumpWorkspace(forTabId: workspaceId)?.preferredUnreadPanelIdForJump()
    }

    func shouldTriggerManualUnreadJumpFlash(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let workspace = unreadJumpWorkspace(forTabId: workspaceId) else { return false }
        return workspace.manualUnreadPanelIds.contains(panelId) ||
            workspace.hasRestoredUnreadIndicator(panelId: panelId) ||
            (notificationStore?.hasManualUnread(forTabId: workspaceId) ?? false) ||
            (notificationStore?.hasRestoredUnreadIndicator(forTabId: workspaceId) ?? false)
    }

    func triggerUnreadIndicatorDismissFlash(workspaceId: UUID, panelId: UUID) {
        unreadJumpWorkspace(forTabId: workspaceId)?.triggerUnreadIndicatorDismissFlash(panelId: panelId)
    }

    func clearUnreadAfterJump(workspaceId: UUID, panelId: UUID?) {
        unreadJumpWorkspace(forTabId: workspaceId)?.clearUnreadAfterJump(panelId: panelId)
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

extension AppDelegate: FinderRevealing {
    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func selectFileInFinder(path: String) -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        // `activateFileViewerSelecting` returns no status; the legacy
        // `revealInFinder` returned `true` on this branch.
        return true
    }

    func openDirectoryInFinder(path: String) -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

extension AppDelegate: FocusedNotificationResolving {
    var hasNotificationStore: Bool {
        notificationStore != nil
    }

    func focusedTarget(preferredWindowToken: AnyObject?) -> FocusedNotificationTarget? {
        // The opaque resolver token is the preferred `NSWindow` the legacy
        // `focusedNotificationTarget(preferredWindow:)` took. The resolution
        // itself stays in `AppDelegate.swift` (it reaches the private
        // first-responder/`FocusedTerminalShortcutContext` resolver).
        guard let target = resolveFocusedNotificationTarget(preferredWindow: preferredWindowToken as? NSWindow) else {
            return nil
        }
        return FocusedNotificationTarget(tabId: target.tabId, surfaceId: target.surfaceId)
    }

    func focusedPanel(forTabId tabId: UUID, surfaceId: UUID?) -> FocusedPanel? {
        guard let surfaceId,
              let workspace = workspaceFor(tabId: tabId) else {
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
        return FocusedPanel(tabId: tabId, panelId: panelId)
    }

    func panelHasRestoredUnread(_ panel: FocusedPanel) -> Bool {
        workspaceFor(tabId: panel.tabId)?.hasRestoredUnreadIndicator(panelId: panel.panelId) ?? false
    }

    func workspaceHasContributingRestoredUnread(_ panel: FocusedPanel) -> Bool {
        workspaceFor(tabId: panel.tabId)?.hasWorkspaceContributingRestoredUnreadIndicator ?? false
    }

    func panelIsManualUnread(_ panel: FocusedPanel) -> Bool {
        workspaceFor(tabId: panel.tabId)?.manualUnreadPanelIds.contains(panel.panelId) ?? false
    }

    func panelIsRepresentativeForWorkspaceManualUnread(_ panel: FocusedPanel) -> Bool {
        workspaceFor(tabId: panel.tabId)?.representativePanelIdForWorkspaceManualUnread() == panel.panelId
    }

    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        notificationStore?.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: surfaceId) ?? false
    }

    func storeHasManualUnread(forTabId tabId: UUID) -> Bool {
        notificationStore?.hasManualUnread(forTabId: tabId) ?? false
    }

    func storeHasRestoredUnread(forTabId tabId: UUID) -> Bool {
        notificationStore?.hasRestoredUnreadIndicator(forTabId: tabId) ?? false
    }

    func workspaceIsUnread(forTabId tabId: UUID) -> Bool {
        notificationStore?.workspaceIsUnread(forTabId: tabId) ?? false
    }

    func storeMarkRead(forTabId tabId: UUID) {
        notificationStore?.markRead(forTabId: tabId)
    }

    func storeMarkUnread(forTabId tabId: UUID) {
        notificationStore?.markUnread(forTabId: tabId)
    }

    func storeClearManualUnread(forTabId tabId: UUID) {
        _ = notificationStore?.clearManualUnread(forTabId: tabId)
    }

    func markPanelRead(_ panel: FocusedPanel) {
        workspaceFor(tabId: panel.tabId)?.markPanelRead(panel.panelId)
    }

    func markPanelUnread(_ panel: FocusedPanel) {
        workspaceFor(tabId: panel.tabId)?.markPanelUnread(panel.panelId)
    }

    func markLatestNotificationAsOldestUnread(forTabId tabId: UUID, surfaceId: UUID?) -> UUID? {
        notificationStore?.markLatestNotificationAsOldestUnread(forTabId: tabId, surfaceId: surfaceId)
    }
}
