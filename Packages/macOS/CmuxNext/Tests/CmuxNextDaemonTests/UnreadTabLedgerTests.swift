import Testing
@testable import CmuxNextDaemon

/// A workspace's unread count is kept as tabs change (``UnreadTabLedger``), not walked on each
/// read: the badge and the sidebar read every workspace's count on each model change, and the walk
/// over every screen, pane and tab cost 53 ms of main thread on one STRESS Close Pane (sweep
/// 2026-10-23, `NotificationCenterService.unreadCount`).
@MainActor
struct UnreadTabLedgerTests {
    /// Workspace `id` with `tabs` tabs in one pane; tab surfaces from `first`; the tabs in
    /// `unread` (surface numbers) hold an unread notification.
    private static func workspace(_ id: UInt64, tabs: Int, first: UInt64, unread: Set<UInt64> = [],
                                  pane: UInt64? = nil) -> WorkspaceSnapshot {
        let paneID = PaneID(rawValue: pane ?? id * 10)
        let snapshots = (0..<UInt64(tabs)).map { offset -> TabSnapshot in
            let surface = first + offset
            let note = unread.contains(surface) ? TabNotification(notification: NotificationID(rawValue: surface), unread: true) : nil
            return TabSnapshot(surface: SurfaceID(rawValue: surface), notification: note)
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: id * 10), layout: .leaf(paneID), panes: [PaneSnapshot(id: paneID, tabs: snapshots)])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(id)", screens: [screen])
    }

    @Test func countsFollowNotificationsReadsAndRemovals() throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [Self.workspace(1, tabs: 3, first: 100, unread: [100]),
                                                      Self.workspace(2, tabs: 2, first: 200)]))
        let first = try #require(store.workspaces.first { $0.handle == WorkspaceHandle(rawValue: 1) })
        let second = try #require(store.workspaces.first { $0.handle == WorkspaceHandle(rawValue: 2) })
        #expect(first.unreadCount == 1)
        #expect(second.unreadCount == 0)

        // One notification changes one count.
        store.apply(snapshot: DaemonTree(workspaces: [Self.workspace(1, tabs: 3, first: 100, unread: [100]),
                                                      Self.workspace(2, tabs: 2, first: 200, unread: [201])]))
        #expect(first.unreadCount == 1)
        #expect(second.unreadCount == 1)

        // A read the client expects shows at once.
        store.tab(surface: SurfaceID(rawValue: 100))?.expectNotificationRead()
        #expect(first.unreadCount == 0)
        store.tab(surface: SurfaceID(rawValue: 100))?.dropExpectedNotificationRead()
        #expect(first.unreadCount == 1)

        // A closed tab leaves the count.
        store.apply(snapshot: DaemonTree(workspaces: [Self.workspace(1, tabs: 3, first: 100, unread: [100]),
                                                      Self.workspace(2, tabs: 1, first: 200)]))
        #expect(second.unreadCount == 0)
        #expect(first.unreadCount == 1)
    }

    /// The same number of reads costs about the same for a workspace of 12 tabs and one of 1200.
    /// A walk makes each read about 100 times as costly in the larger one; a kept count costs the
    /// same. The bound of 8 sits between the two with room for timing noise (the fastest of five
    /// runs of each is compared).
    @Test func readCostDoesNotGrowWithTheTabs() throws {
        func cost(tabs: Int) throws -> Duration {
            let store = DaemonStore()
            store.apply(snapshot: DaemonTree(workspaces: [Self.workspace(1, tabs: tabs, first: 1, unread: [1])]))
            let workspace = try #require(store.workspaces.first)
            let clock = ContinuousClock()
            var fastest = Duration.seconds(3_600)
            var total = 0
            for _ in 0..<5 {
                let elapsed = clock.measure { for _ in 0..<1_000 { total += workspace.unreadCount } }
                fastest = min(fastest, elapsed)
            }
            #expect(total == 5_000)
            return fastest
        }
        let small = try cost(tabs: 12), large = try cost(tabs: 1_200)
        let ratio = large / max(small, .nanoseconds(1))
        #expect(ratio < 8, "a read in a 1200-tab workspace cost \(ratio)x one in a 12-tab workspace (\(large) vs \(small))")
    }
}
