import AppKit
import Bonsplit
import CmuxNotifications
import Foundation

/// App-side adapter that lets the `CmuxNotifications` navigation seams reach
/// `AppDelegate` WITHOUT forming a retain cycle. The coordinator (and the
/// `NotificationClickPerformer`) store their seams as strong `any …` refs, so if
/// `AppDelegate` injected `self` the graph would be
/// `AppDelegate → coordinator → AppDelegate` (a strong cycle). Production is a
/// forever-singleton, but the app-host tests create/replace `AppDelegate`, so a
/// cycle pins the test instance and it can never deallocate.
///
/// The fix: this adapter holds a `weak var owner: AppDelegate?` and conforms to
/// every seam by forwarding to internal `AppDelegate` helpers. `AppDelegate`
/// builds the coordinator and click performer from the adapter, so the graph is
/// `AppDelegate → {adapter, coordinator}; coordinator → adapter (strong);
/// adapter → AppDelegate (weak)` — no strong path back to `AppDelegate`.
///
/// The package keeps STRONG seam storage on purpose: its own tests pass fakes
/// that are only retained by the coordinator. Weakness is introduced here, on
/// the app side, exactly at the `owner` edge. When the owner is alive (the only
/// case that occurs in production and in the package tests) every method is
/// byte-identical to the old `AppDelegate` conformance; when it has deallocated
/// each method degrades to the same empty/no-op/false/nil the seams already use
/// for missing late-bound state.
///
/// Legal per CONVENTIONS §6: the adapter is app-target-owned and keeps the window
/// mechanics, `#if DEBUG` UI-test recorders, and Combine app-side while the
/// orchestration stays in the package.
@MainActor
final class NotificationNavSeamAdapter:
    NotificationNavigationStoreReading,
    MainWindowContextResolving,
    UnreadWorkspaceTargeting,
    NotificationOpenRouting,
    FinderRevealing,
    FocusedNotificationResolving
{
    weak var owner: AppDelegate?

    init(owner: AppDelegate) {
        self.owner = owner
    }

    // MARK: NotificationNavigationStoreReading

    var orderedNotifications: [NotificationNavSnapshot] {
        owner?.orderedNotificationsForNav ?? []
    }

    var workspaceUnreadIndicatorIds: Set<UUID> {
        owner?.workspaceUnreadIndicatorIdsForNav ?? []
    }

    func hasManualUnread(forTabId tabId: UUID) -> Bool {
        owner?.navStoreHasManualUnread(forTabId: tabId) ?? false
    }

    func hasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool {
        owner?.navStoreHasRestoredUnreadIndicator(forTabId: tabId) ?? false
    }

    func markRead(id: UUID) {
        owner?.navMarkRead(id: id)
    }

    // MARK: MainWindowContextResolving

    var orderedTargetsForUnreadJump: [MainWindowTarget] {
        owner?.orderedTargetsForUnreadJump ?? []
    }

    var activeWorkspaceIdsForUnreadJump: [UUID] {
        owner?.activeWorkspaceIdsForUnreadJump ?? []
    }

    // MARK: UnreadWorkspaceTargeting

    func preferredUnreadPanelIdForJump(workspaceId: UUID) -> UUID? {
        owner?.preferredUnreadPanelIdForJump(workspaceId: workspaceId) ?? nil
    }

    func shouldTriggerManualUnreadJumpFlash(workspaceId: UUID, panelId: UUID) -> Bool {
        owner?.shouldTriggerManualUnreadJumpFlash(workspaceId: workspaceId, panelId: panelId) ?? false
    }

    func triggerUnreadIndicatorDismissFlash(workspaceId: UUID, panelId: UUID) {
        owner?.triggerUnreadIndicatorDismissFlash(workspaceId: workspaceId, panelId: panelId)
    }

    func clearUnreadAfterJump(workspaceId: UUID, panelId: UUID?) {
        owner?.clearUnreadAfterJump(workspaceId: workspaceId, panelId: panelId)
    }

    // MARK: NotificationOpenRouting

    func openRouted(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        owner?.openRouted(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId) ?? false
    }

    func openInWindow(windowId: UUID, tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        owner?.openInWindow(
            windowId: windowId,
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId
        ) ?? false
    }

    func openInActiveWindowFallback(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        owner?.openInActiveWindowFallback(
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId
        ) ?? false
    }

    func tabTitle(forTabId tabId: UUID) -> String? {
        owner?.tabTitle(forTabId: tabId) ?? nil
    }

    // MARK: FinderRevealing

    func fileExists(atPath path: String) -> Bool {
        owner?.finderFileExists(atPath: path) ?? false
    }

    func selectFileInFinder(path: String) -> Bool {
        owner?.finderSelectFile(path: path) ?? false
    }

    func openDirectoryInFinder(path: String) -> Bool {
        owner?.finderOpenDirectory(path: path) ?? false
    }

    // MARK: FocusedNotificationResolving

    var hasNotificationStore: Bool {
        owner?.hasNotificationStore ?? false
    }

    func focusedTarget(preferredWindowToken: AnyObject?) -> FocusedNotificationTarget? {
        owner?.focusedTarget(preferredWindowToken: preferredWindowToken) ?? nil
    }

    func focusedPanel(forTabId tabId: UUID, surfaceId: UUID?) -> FocusedPanel? {
        owner?.focusedPanel(forTabId: tabId, surfaceId: surfaceId) ?? nil
    }

    func panelHasRestoredUnread(_ panel: FocusedPanel) -> Bool {
        owner?.panelHasRestoredUnread(panel) ?? false
    }

    func workspaceHasContributingRestoredUnread(_ panel: FocusedPanel) -> Bool {
        owner?.workspaceHasContributingRestoredUnread(panel) ?? false
    }

    func panelIsManualUnread(_ panel: FocusedPanel) -> Bool {
        owner?.panelIsManualUnread(panel) ?? false
    }

    func panelIsRepresentativeForWorkspaceManualUnread(_ panel: FocusedPanel) -> Bool {
        owner?.panelIsRepresentativeForWorkspaceManualUnread(panel) ?? false
    }

    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        owner?.hasVisibleNotificationIndicator(forTabId: tabId, surfaceId: surfaceId) ?? false
    }

    func storeHasManualUnread(forTabId tabId: UUID) -> Bool {
        owner?.storeHasManualUnread(forTabId: tabId) ?? false
    }

    func storeHasRestoredUnread(forTabId tabId: UUID) -> Bool {
        owner?.storeHasRestoredUnread(forTabId: tabId) ?? false
    }

    func workspaceIsUnread(forTabId tabId: UUID) -> Bool {
        owner?.workspaceIsUnread(forTabId: tabId) ?? false
    }

    func storeMarkRead(forTabId tabId: UUID) {
        owner?.storeMarkRead(forTabId: tabId)
    }

    func storeMarkUnread(forTabId tabId: UUID) {
        owner?.storeMarkUnread(forTabId: tabId)
    }

    func storeClearManualUnread(forTabId tabId: UUID) {
        owner?.storeClearManualUnread(forTabId: tabId)
    }

    func markPanelRead(_ panel: FocusedPanel) {
        owner?.markPanelRead(panel)
    }

    func markPanelUnread(_ panel: FocusedPanel) {
        owner?.markPanelUnread(panel)
    }

    func markLatestNotificationAsOldestUnread(forTabId tabId: UUID, surfaceId: UUID?) -> UUID? {
        owner?.markLatestNotificationAsOldestUnread(forTabId: tabId, surfaceId: surfaceId) ?? nil
    }
}

/// Internal helpers the `NotificationNavSeamAdapter` forwards to. These are the
/// original seam bodies, lifted off the protocol conformances (which now live on
/// the adapter) and kept on `AppDelegate` so they retain access to the
/// late-bound window/tab/store state. Behavior is byte-identical to the previous
/// `AppDelegate: <seam>` conformances.
extension AppDelegate {
    // MARK: NotificationNavigationStoreReading helpers

    var orderedNotificationsForNav: [NotificationNavSnapshot] {
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

    var workspaceUnreadIndicatorIdsForNav: Set<UUID> {
        notificationStore?.workspaceUnreadIndicatorIds ?? []
    }

    func navStoreHasManualUnread(forTabId tabId: UUID) -> Bool {
        notificationStore?.hasManualUnread(forTabId: tabId) ?? false
    }

    func navStoreHasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool {
        notificationStore?.hasRestoredUnreadIndicator(forTabId: tabId) ?? false
    }

    func navMarkRead(id: UUID) {
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

    // MARK: MainWindowContextResolving helpers

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

    // MARK: UnreadWorkspaceTargeting helpers

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

    // MARK: NotificationOpenRouting helpers

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

    // MARK: FinderRevealing helpers

    func finderFileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func finderSelectFile(path: String) -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        // `activateFileViewerSelecting` returns no status; the legacy
        // `revealInFinder` returned `true` on this branch.
        return true
    }

    func finderOpenDirectory(path: String) -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: FocusedNotificationResolving helpers

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
