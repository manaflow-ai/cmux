@testable import CmuxNextDaemon
import CmuxNextCompat
import Observation
import Testing

/// The unread counts cost what changed (m26/m27 STRESS daemon-store-apply: newWindow 243 ms,
/// workspace.newAtBottom 225 ms, moveSurfaceToPaneDown 111 ms in Observation's cancel and
/// re-registration). The Dock badge, the notification panel and each window's sidebar observed a
/// count that read every tab of every workspace, so any tab-list change or notification
/// re-registered and re-read all tabs. The store keeps the counts per workspace and the badge
/// reads one value; every path that changes them keeps them equal to a count from all tabs.
@MainActor @Suite struct StoreUnreadTotalsTests {
    private static let workspaces = 100
    private static let tabsPerWorkspace = 5

    private static func surface(_ workspace: Int, _ tab: Int) -> SurfaceID { SurfaceID(rawValue: UInt64(workspace * 100 + 10 + tab)) }
    private static func pane(_ workspace: Int) -> PaneID { PaneID(rawValue: UInt64(workspace * 100 + 1)) }
    private static func screen(_ workspace: Int) -> ScreenID { ScreenID(rawValue: UInt64(workspace * 100 + 2)) }
    private static func handle(_ workspace: Int) -> WorkspaceHandle { WorkspaceHandle(rawValue: UInt64(workspace * 100 + 3)) }

    private static func tab(_ workspace: Int, _ tab: Int, unread notification: UInt64? = nil) -> TabSnapshot {
        TabSnapshot(surface: surface(workspace, tab),
                    notification: notification.map { TabNotification(notification: NotificationID(rawValue: $0), unread: true) })
    }

    private static func workspace(_ index: Int, tabs: [TabSnapshot]? = nil, markedUnread: Bool = false) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: pane(index), tabs: tabs ?? (0..<tabsPerWorkspace).map { tab(index, $0) })
        let screen = ScreenSnapshot(id: screen(index), layout: .leaf(pane.id), panes: [pane])
        var snapshot = WorkspaceSnapshot(id: handle(index), key: nil, name: "w\(index)", screens: [screen])
        snapshot.markedUnread = markedUnread
        return snapshot
    }

    /// 100 workspaces of 5 tabs: 500 tabs.
    private func loadedStore() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: (0..<Self.workspaces).map { Self.workspace($0) }))
        return store
    }

    private func notify(_ store: DaemonStore, workspace: Int, tab: Int, id: UInt64) {
        _ = store.apply(.tabChanged(TabDelta(workspace: Self.handle(workspace), screen: Self.screen(workspace), pane: Self.pane(workspace),
                                             surface: Self.surface(workspace, tab), index: tab, entity: Self.tab(workspace, tab, unread: id))))
    }

    /// The stored counts equal a count from every tab.
    private func expectConsistent(_ store: DaemonStore, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        let recounted = store.recountedUnreadTotals()
        #expect(store.unreadBadge() == recounted.tabs, comment, sourceLocation: sourceLocation)
        #expect(store.unreadBadge(homeUnread: ["c-1", "c-2"]) == recounted.badge(homeUnread: ["c-1", "c-2"]), comment,
                sourceLocation: sourceLocation)
    }

    @Test func oneNotificationAmongFiveHundredTabsReadsNoTabForTheBadge() {
        let store = loadedStore()
        let changed = Heard()
        withObservationTracking { _ = store.unreadBadge() } onChange: { changed.set() }
        notify(store, workspace: 42, tab: 3, id: 9)
        #expect(changed.value, "the badge's observer heard the notification")
        let reads = store.unreadTabReads
        #expect(store.unreadBadge() == 1)
        #expect(store.unreadTabReads - reads == 0,
                "reading the badge after one notification read \(store.unreadTabReads - reads) of 500 tabs")
        #expect(store.workspaces[42].unreadCount == 1)
        expectConsistent(store, "after one notification")
    }

    /// What the badge observes changes only with the count: a retitled tab or a new tab with no
    /// notification does not wake the Dock badge, the notification panel or a window's sidebar.
    @Test func aTitleChangeOrANewTabWithoutANotificationDoesNotWakeTheBadge() {
        let store = loadedStore()
        notify(store, workspace: 2, tab: 0, id: 4)
        let changed = Heard()
        withObservationTracking { _ = store.unreadBadge(homeUnread: ["c-1"]) } onChange: { changed.set() }
        _ = store.apply(.titleChanged(surface: Self.surface(2, 1), title: "vim README.md"))
        _ = store.apply(.tabAdded(TabDelta(workspace: Self.handle(2), screen: Self.screen(2), pane: Self.pane(2),
                                           surface: Self.surface(2, 9), index: 5, entity: Self.tab(2, 9))))
        _ = store.apply(.tabChanged(TabDelta(workspace: Self.handle(3), screen: Self.screen(3), pane: Self.pane(3),
                                             surface: Self.surface(3, 0), index: 0, entity: Self.tab(3, 0))))
        #expect(!changed.value, "the badge's observer woke for a change that left the count as it was")
        notify(store, workspace: 3, tab: 1, id: 5)
        #expect(changed.value, "the badge's observer missed a new unread notification")
        expectConsistent(store, "after unrelated changes")
    }

    @Test func closingAnUnreadTabDropsItsCount() {
        let store = loadedStore()
        notify(store, workspace: 7, tab: 1, id: 1)
        notify(store, workspace: 7, tab: 2, id: 2)
        #expect(store.unreadBadge() == 2)
        _ = store.apply(.tabClosed(TabDelta(workspace: Self.handle(7), screen: Self.screen(7), pane: Self.pane(7), surface: Self.surface(7, 1),
                                            index: nil, entity: Self.tab(7, 1, unread: 1))))
        #expect(store.unreadBadge() == 1)
        #expect(store.workspaces[7].unreadCount == 1)
        expectConsistent(store, "after a close")
    }

    @Test func anUnreadTabMovedToAnotherWorkspaceMovesItsCount() {
        let store = loadedStore()
        notify(store, workspace: 3, tab: 0, id: 5)
        // Move Tab to Workspace: the tab's tab-changed names the other workspace's pane.
        _ = store.apply(.tabChanged(TabDelta(workspace: Self.handle(8), screen: Self.screen(8), pane: Self.pane(8), surface: Self.surface(3, 0),
                                             index: 0, entity: Self.tab(3, 0, unread: 5))))
        #expect(store.workspaces[3].unreadCount == 0)
        #expect(store.workspaces[8].unreadCount == 1)
        #expect(store.unreadBadge() == 1)
        expectConsistent(store, "after a move between workspaces")
    }

    @Test func closingAWorkspaceDropsItsCount() {
        let store = loadedStore()
        notify(store, workspace: 5, tab: 0, id: 1)
        notify(store, workspace: 6, tab: 0, id: 2)
        _ = store.apply(.workspaceClosed(WorkspaceDelta(workspace: Self.handle(5), index: nil, entity: Self.workspace(5), workspaceRevision: 2)))
        #expect(store.unreadBadge() == 1)
        expectConsistent(store, "after a workspace close")
    }

    @Test func readingANotificationAndAMarkedWorkspaceKeepTheCountsEqual() throws {
        let store = loadedStore()
        notify(store, workspace: 9, tab: 4, id: 3)
        let tab = try #require(store.tab(surface: Self.surface(9, 4)))
        // This client read it: the count drops before the daemon's echo.
        tab.expectNotificationRead()
        #expect(store.unreadBadge() == 0)
        expectConsistent(store, "after a read")
        tab.dropExpectedNotificationRead()
        #expect(store.unreadBadge() == 1)
        // A workspace marked unread by hand, with no unread tab, counts one.
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: (0..<Self.workspaces).map {
            Self.workspace($0, tabs: $0 == 9 ? (0..<Self.tabsPerWorkspace).map { Self.tab(9, $0, unread: $0 == 4 ? 3 : nil) } : nil,
                           markedUnread: $0 == 11)
        }))
        #expect(store.unreadBadge() == 2)
        expectConsistent(store, "after a mark")
    }
}

/// An observer's onChange ran (it may run on any thread).
private final class Heard: Sendable {
    private let heard = Mutex(false)
    nonisolated deinit {}
    var value: Bool { heard.withLock { $0 } }
    func set() { heard.withLock { $0 = true } }
}
