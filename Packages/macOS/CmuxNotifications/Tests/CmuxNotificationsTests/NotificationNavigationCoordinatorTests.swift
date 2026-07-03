import Foundation
import Testing
@testable import CmuxNotifications

// MARK: - Fakes

/// Scriptable notification store: an ordered snapshot list plus the unread-id
/// set and the two unread predicates, with a log of every `markRead`.
@MainActor
private final class FakeStore: NotificationNavigationStoreReading {
    var orderedNotifications: [NotificationNavSnapshot] = []
    var workspaceUnreadIndicatorIds: Set<UUID> = []
    var manualUnreadTabs: Set<UUID> = []
    var restoredUnreadTabs: Set<UUID> = []
    private(set) var markedReadIds: [UUID] = []

    func hasManualUnread(forTabId tabId: UUID) -> Bool { manualUnreadTabs.contains(tabId) }
    func hasRestoredUnreadIndicator(forTabId tabId: UUID) -> Bool { restoredUnreadTabs.contains(tabId) }
    func markRead(id: UUID) { markedReadIds.append(id) }
}

/// Scriptable window resolver: an ordered target list for the unread jump.
@MainActor
private final class FakeWindows: MainWindowContextResolving {
    var orderedTargetsForUnreadJump: [MainWindowTarget] = []
    var activeWorkspaceIdsForUnreadJump: [UUID] = []
}

/// Scriptable unread targeting: a per-workspace preferred panel and flash
/// predicate, with a log of flash + clear calls.
@MainActor
private final class FakeUnreadTargeting: UnreadWorkspaceTargeting {
    var preferredPanelByWorkspace: [UUID: UUID] = [:]
    var shouldFlashByWorkspacePanel: Set<PanelKey> = []
    private(set) var flashedPanels: [PanelKey] = []
    private(set) var clearedJumps: [(UUID, UUID?)] = []

    struct PanelKey: Hashable { let workspaceId: UUID; let panelId: UUID }

    func preferredUnreadPanelIdForJump(workspaceId: UUID) -> UUID? {
        preferredPanelByWorkspace[workspaceId]
    }

    func shouldTriggerManualUnreadJumpFlash(workspaceId: UUID, panelId: UUID) -> Bool {
        shouldFlashByWorkspacePanel.contains(PanelKey(workspaceId: workspaceId, panelId: panelId))
    }

    func triggerUnreadIndicatorDismissFlash(workspaceId: UUID, panelId: UUID) {
        flashedPanels.append(PanelKey(workspaceId: workspaceId, panelId: panelId))
    }

    func clearUnreadAfterJump(workspaceId: UUID, panelId: UUID?) {
        clearedJumps.append((workspaceId, panelId))
    }
}

/// Recording open router: scriptable success per window/fallback, plus an
/// ordered log of which route was taken with what arguments. The log proves the
/// sidebar-tabs-before-focus ordering is delegated to the app-side seam (the
/// seam is the single place that write happens) and that the coordinator routes
/// to the right window.
@MainActor
private final class FakeOpenRouting: NotificationOpenRouting {
    var windowSucceeds = true
    var fallbackSucceeds = true
    var routedSucceeds = true
    var titles: [UUID: String] = [:]
    private(set) var log: [String] = []

    func openRouted(tabId: UUID, surfaceId: UUID?, panelId: UUID?, notificationId: UUID?, scrollRow: Int?) -> Bool {
        log.append("routed(tab=\(short(tabId)),surf=\(short(surfaceId))\(panel(panelId)),notif=\(short(notificationId)),row=\(row(scrollRow)))")
        return routedSucceeds
    }

    func openInWindow(windowId: UUID, tabId: UUID, surfaceId: UUID?, panelId: UUID?, notificationId: UUID?, scrollRow: Int?) -> Bool {
        log.append("window(\(short(windowId)),tab=\(short(tabId)),surf=\(short(surfaceId))\(panel(panelId)),notif=\(short(notificationId)),row=\(row(scrollRow)))")
        return windowSucceeds
    }

    func openInActiveWindowFallback(tabId: UUID, surfaceId: UUID?, panelId: UUID?, notificationId: UUID?, scrollRow: Int?) -> Bool {
        log.append("fallback(tab=\(short(tabId)),surf=\(short(surfaceId))\(panel(panelId)),notif=\(short(notificationId)),row=\(row(scrollRow)))")
        return fallbackSucceeds
    }

    func tabTitle(forTabId tabId: UUID) -> String? { titles[tabId] }

    private func short(_ id: UUID?) -> String { id.map { String($0.uuidString.prefix(4)) } ?? "nil" }
    private func panel(_ id: UUID?) -> String { id.map { ",panel=\(short($0))" } ?? "" }
    private func row(_ row: Int?) -> String { row.map(String.init) ?? "nil" }
}

/// Recording click router: scriptable success plus a log of performed actions.
@MainActor
private final class FakeClickRouting: NotificationClickRouting {
    var succeeds = true
    private(set) var performed: [NotificationNavClickAction] = []

    func perform(_ action: NotificationNavClickAction) -> Bool {
        performed.append(action)
        return succeeds
    }
}

@MainActor
private func makeCoordinator(
    store: FakeStore = FakeStore(),
    windows: FakeWindows = FakeWindows(),
    unreadTargeting: FakeUnreadTargeting = FakeUnreadTargeting(),
    openRouting: FakeOpenRouting = FakeOpenRouting(),
    clickRouting: FakeClickRouting = FakeClickRouting(),
    focusedResolving: FakeFocusedResolving = FakeFocusedResolving()
) -> NotificationNavigationCoordinator {
    NotificationNavigationCoordinator(
        store: store,
        windows: windows,
        unreadTargeting: unreadTargeting,
        openRouting: openRouting,
        clickRouting: clickRouting,
        focusedResolving: focusedResolving
    )
}

private func snapshot(
    tabId: UUID,
    surfaceId: UUID? = nil,
    panelId: UUID? = nil,
    isRead: Bool = false,
    clickAction: NotificationNavClickAction? = nil,
    scrollRow: Int? = nil,
    id: UUID = UUID()
) -> NotificationNavSnapshot {
    NotificationNavSnapshot(
        id: id,
        tabId: tabId,
        surfaceId: surfaceId,
        panelId: panelId,
        isRead: isRead,
        clickAction: clickAction,
        scrollRow: scrollRow
    )
}

// MARK: - Jump selection

@Suite(.serialized)
@MainActor
struct NotificationNavigationCoordinatorTests {
    @Test("jumpToLatestUnread opens the first openable unread in store order")
    func picksLatestUnread() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let tabA = UUID(), tabB = UUID()
        // First (latest) is read, second is the latest *openable* unread.
        let read = snapshot(tabId: tabA, isRead: true)
        let openable = snapshot(tabId: tabB)
        store.orderedNotifications = [read, openable]
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        let openedId = coordinator.jumpToLatestUnread()

        #expect(openedId == openable.id)
        // Only the openable one was routed (the read one is skipped); it routes
        // through the full app-side `openNotification` (openRouted) with the
        // notification id, which marks read on success app-side.
        #expect(openRouting.log == ["routed(tab=\(short(tabB)),surf=nil,notif=\(short(openable.id)),row=nil)"])
    }

    @Test("jumpToLatestUnread skips notifications with a click action in the scan")
    func skipsClickActionInScan() {
        let store = FakeStore()
        let openRouting = FakeOpenRouting()
        let tab = UUID()
        // A click-action notification is not openable-for-jump; with no other
        // unread and no unread-workspace fallback, the jump opens nothing.
        store.orderedNotifications = [snapshot(tabId: tab, clickAction: .revealInFinder(path: "/tmp/x"))]
        let coordinator = makeCoordinator(store: store, openRouting: openRouting)

        let openedId = coordinator.jumpToLatestUnread()

        #expect(openedId == nil)
        #expect(openRouting.log.isEmpty)
    }

    @Test("jumpToLatestUnread honors the excluded notification id")
    func honorsExcludedNotification() {
        let store = FakeStore()
        let tab = UUID()
        let excluded = snapshot(tabId: tab)
        let next = snapshot(tabId: tab)
        store.orderedNotifications = [excluded, next]
        let coordinator = makeCoordinator(store: store)

        let openedId = coordinator.jumpToLatestUnread(excludingNotificationId: excluded.id)

        #expect(openedId == next.id)
    }

    // MARK: - Workspace-unread fallback + flash/clear

    @Test("falls back to unread-workspace jump and clears unread, flashing when manual")
    func fallbackJumpFlashesAndClears() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tab = UUID(), panel = UUID(), windowId = UUID()
        // No openable notifications, but the workspace carries an unread indicator.
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: windowId, workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = panel
        unread.shouldFlashByWorkspacePanel = [.init(workspaceId: tab, panelId: panel)]
        let coordinator = makeCoordinator(
            store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting
        )

        let openedId = coordinator.jumpToLatestUnread()

        #expect(openedId == nil) // workspace-unread fallback returns nil notification id
        #expect(openRouting.log == ["window(\(short(windowId)),tab=\(short(tab)),surf=\(short(panel)),notif=nil,row=nil)"])
        #expect(unread.flashedPanels == [.init(workspaceId: tab, panelId: panel)])
        #expect(unread.clearedJumps.count == 1)
        #expect(unread.clearedJumps.first?.0 == tab)
        #expect(unread.clearedJumps.first?.1 == panel)
    }

    @Test("workspace-unread jump does NOT flash when not manual, but still clears")
    func fallbackJumpClearsWithoutFlashWhenNotManual() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let tab = UUID(), panel = UUID(), windowId = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: windowId, workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = panel
        // shouldFlash is empty → no flash.
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread)

        _ = coordinator.jumpToLatestUnread()

        #expect(unread.flashedPanels.isEmpty)
        #expect(unread.clearedJumps.count == 1)
    }

    @Test("workspace-unread jump that fails to open does not clear or flash")
    func failedWorkspaceJumpDoesNotClear() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        openRouting.windowSucceeds = false
        openRouting.fallbackSucceeds = false
        let tab = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: UUID(), workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = UUID()
        let coordinator = makeCoordinator(
            store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting
        )

        _ = coordinator.jumpToLatestUnread()

        #expect(unread.clearedJumps.isEmpty)
        #expect(unread.flashedPanels.isEmpty)
    }

    @Test("workspace-unread jump falls back to the active tab manager when the window-context registry is empty (early-startup/VM timing)")
    func workspaceUnreadFallsBackToActiveManagerWhenRegistryEmpty() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let openRouting = FakeOpenRouting()
        let tab = UUID(), panel = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        // Registry lags during early startup: no targets...
        windows.orderedTargetsForUnreadJump = []
        // ...but the active tab manager already owns the unread workspace.
        windows.activeWorkspaceIdsForUnreadJump = [tab]
        unread.preferredPanelByWorkspace[tab] = panel
        let coordinator = makeCoordinator(
            store: store, windows: windows, unreadTargeting: unread, openRouting: openRouting
        )

        _ = coordinator.jumpToLatestUnread()

        // The active-window fallback opened it (the registry loop had nothing).
        #expect(openRouting.log.contains { $0.hasPrefix("fallback(tab=\(String(tab.uuidString.prefix(4)))") })
        #expect(unread.clearedJumps.count == 1)
        #expect(unread.clearedJumps.first?.0 == tab)
    }

    // MARK: - Click action

    @Test("openNotification performs the click action and marks read on success")
    func clickActionMarksReadOnSuccess() {
        let store = FakeStore()
        let click = FakeClickRouting()
        let openRouting = FakeOpenRouting()
        let notif = snapshot(tabId: UUID(), clickAction: .revealInFinder(path: "/tmp/file"))
        let coordinator = makeCoordinator(store: store, openRouting: openRouting, clickRouting: click)

        let opened = coordinator.openNotification(notif)

        #expect(opened)
        #expect(click.performed == [.revealInFinder(path: "/tmp/file")])
        #expect(store.markedReadIds == [notif.id])
        // No window routing for a click-action notification.
        #expect(openRouting.log.isEmpty)
    }

    @Test("openNotification does NOT mark read when the click action fails")
    func clickActionNotMarkedReadOnFailure() {
        let store = FakeStore()
        let click = FakeClickRouting()
        click.succeeds = false
        let notif = snapshot(tabId: UUID(), clickAction: .revealInFinder(path: "/tmp/file"))
        let coordinator = makeCoordinator(store: store, clickRouting: click)

        let opened = coordinator.openNotification(notif)

        #expect(!opened)
        #expect(store.markedReadIds.isEmpty)
    }

    // MARK: - Open routing

    @Test("open delegates to the app-side routed open (which owns window/fallback choice)")
    func openDelegatesToRoutedOpen() {
        let openRouting = FakeOpenRouting()
        let tab = UUID(), surface = UUID(), notifId = UUID()
        let coordinator = makeCoordinator(openRouting: openRouting)

        let opened = coordinator.open(tabId: tab, surfaceId: surface, notificationId: notifId)

        #expect(opened)
        #expect(openRouting.log == ["routed(tab=\(short(tab)),surf=\(short(surface)),notif=\(short(notifId)),row=nil)"])
    }

    @Test("openNotification without a click action routes through the app-side routed open")
    func openNotificationWithoutClickActionRoutes() {
        let openRouting = FakeOpenRouting()
        let click = FakeClickRouting()
        let notif = snapshot(tabId: UUID(), surfaceId: UUID())
        let coordinator = makeCoordinator(openRouting: openRouting, clickRouting: click)

        let opened = coordinator.openNotification(notif)

        #expect(opened)
        #expect(click.performed.isEmpty)
        #expect(openRouting.log == ["routed(tab=\(short(notif.tabId)),surf=\(short(notif.surfaceId)),notif=\(short(notif.id)),row=nil)"])
    }

    @Test("openNotification routes captured scroll row for terminal notifications")
    func openNotificationRoutesCapturedScrollRow() {
        let openRouting = FakeOpenRouting()
        let panelId = UUID()
        let notif = snapshot(tabId: UUID(), surfaceId: UUID(), panelId: panelId, scrollRow: 42)
        let coordinator = makeCoordinator(openRouting: openRouting)

        let opened = coordinator.openNotification(notif)

        #expect(opened)
        #expect(openRouting.log == ["routed(tab=\(short(notif.tabId)),surf=\(short(notif.surfaceId)),panel=\(short(panelId)),notif=\(short(notif.id)),row=42)"])
    }

    // MARK: - Focus signal (the #if DEBUG recorder hook)

    @Test("a successful workspace-unread jump signals onDidFocusForJumpUnread")
    func successfulJumpSignalsFocus() {
        let store = FakeStore()
        let windows = FakeWindows()
        let unread = FakeUnreadTargeting()
        let tab = UUID(), panel = UUID(), windowId = UUID()
        store.workspaceUnreadIndicatorIds = [tab]
        windows.orderedTargetsForUnreadJump = [MainWindowTarget(windowId: windowId, workspaceIds: [tab])]
        unread.preferredPanelByWorkspace[tab] = panel
        let coordinator = makeCoordinator(store: store, windows: windows, unreadTargeting: unread)
        var signalled: [(UUID, UUID?)] = []
        coordinator.onDidFocusForJumpUnread = { signalled.append(($0, $1)) }

        _ = coordinator.jumpToLatestUnread()

        #expect(signalled.count == 1)
        #expect(signalled.first?.0 == tab)
        #expect(signalled.first?.1 == panel)
    }

    // MARK: - tabTitle

    @Test("tabTitle forwards to the open router")
    func tabTitleForwards() {
        let openRouting = FakeOpenRouting()
        let tab = UUID()
        openRouting.titles[tab] = "My Workspace"
        let coordinator = makeCoordinator(openRouting: openRouting)

        #expect(coordinator.tabTitle(forTabId: tab) == "My Workspace")
    }

    private func short(_ id: UUID?) -> String { id.map { String($0.uuidString.prefix(4)) } ?? "nil" }
}
