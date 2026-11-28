import Foundation
import Testing
@testable import CmuxNextDaemon

/// The store's work for one Cmd-N, one Cmd-D and one notification is the same at 8 workspaces and at 5,000 (Leo,
/// 2026-11-04: no "linear time growth degradation in performance just because the app somehow has tons of
/// workspaces"). Counted, not timed: the unread totals visit only the workspaces a change touched
/// (`unreadWorkspaceVisits`), and the sidebar flattening walks the list once, not once per group
/// (`sidebarWorkspaceVisits`).
@MainActor @Suite struct WorkspaceCountScalingTests {
    private static let small = 8
    private static let large = 5_000
    private static let groups = 12

    private static func surface(_ workspace: Int) -> SurfaceID { SurfaceID(rawValue: UInt64(workspace * 100 + 10)) }
    private static func pane(_ workspace: Int) -> PaneID { PaneID(rawValue: UInt64(workspace * 100 + 1)) }
    private static func screen(_ workspace: Int) -> ScreenID { ScreenID(rawValue: UInt64(workspace * 100 + 2)) }
    private static func handle(_ workspace: Int) -> WorkspaceHandle { WorkspaceHandle(rawValue: UInt64(workspace * 100 + 3)) }

    private static func tab(_ workspace: Int, unread notification: UInt64? = nil) -> TabSnapshot {
        TabSnapshot(surface: surface(workspace),
                    notification: notification.map { TabNotification(notification: NotificationID(rawValue: $0), unread: true) })
    }

    private static func workspace(_ index: Int) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: pane(index), tabs: [tab(index)])
        let screen = ScreenSnapshot(id: screen(index), active: true, activePane: pane.id, layout: .leaf(pane.id), panes: [pane])
        return WorkspaceSnapshot(id: handle(index), key: nil, name: "w\(index)", screens: [screen])
    }

    private static func store(_ count: Int) -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: (0..<count).map(workspace)))
        return store
    }

    /// What one action cost the store: the unread totals' workspace visits and the sidebar flattening's.
    private struct Cost: Equatable, CustomStringConvertible {
        var unread: Int
        var sidebar: Int
        var description: String { "unread visits \(unread), sidebar visits \(sidebar)" }
    }

    private static func cost(_ store: DaemonStore, _ action: (DaemonStore) -> Void) -> Cost {
        let unread = store.unreadWorkspaceVisits, sidebar = store.sidebarWorkspaceVisits
        action(store)
        return Cost(unread: store.unreadWorkspaceVisits - unread, sidebar: store.sidebarWorkspaceVisits - sidebar)
    }

    private static func notify(_ store: DaemonStore, workspace: Int, id: UInt64) {
        _ = store.apply(.tabChanged(TabDelta(workspace: handle(workspace), screen: screen(workspace), pane: pane(workspace),
                                             surface: surface(workspace), index: 0, entity: tab(workspace, unread: id))))
    }

    private static func newWorkspace(_ store: DaemonStore) {
        let tab = ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: .generate(), name: "new", tab: tab), index: nil),
                     transaction: .generate())
    }

    private static func split(_ store: DaemonStore, workspace: Int) {
        store.intend(.splitPane(pane: pane(workspace), direction: .right, ratio: 0.5,
                                provisional: ProvisionalPane(holding: ProvisionalTab().terminal(TerminalID.generate(), cwd: nil))),
                     transaction: .generate())
    }

    /// The stored counts equal a count from every tab after the actions.
    private static func expectConsistent(_ store: DaemonStore, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(store.recountedUnreadTotals() == store.unreadTotals, comment, sourceLocation: sourceLocation)
    }

    @Test func oneNotificationVisitsOneWorkspaceWhateverTheCount() {
        var costs: [Int: Cost] = [:]
        for count in [Self.small, Self.large] {
            let store = Self.store(count)
            costs[count] = Self.cost(store) { Self.notify($0, workspace: count / 2, id: 7) }
            #expect(store.unreadBadge() == 1)
            Self.expectConsistent(store, "after a notification among \(count) workspaces")
        }
        #expect(costs[Self.large]?.unread == costs[Self.small]?.unread,
                "one notification visited \(costs[Self.large]?.unread ?? -1) workspaces' unread counts among 5,000, \(costs[Self.small]?.unread ?? -1) among 8")
        #expect((costs[Self.large]?.unread ?? .max) <= 1)
    }

    @Test func cmdNVisitsOnlyTheNewWorkspacesUnreadCount() {
        var costs: [Int: Cost] = [:]
        for count in [Self.small, Self.large] {
            let store = Self.store(count)
            Self.notify(store, workspace: 1, id: 3)
            costs[count] = Self.cost(store) { Self.newWorkspace($0) }
            #expect(store.workspaces.count == count + 1)
            Self.expectConsistent(store, "after Cmd-N among \(count) workspaces")
        }
        #expect(costs[Self.large]?.unread == costs[Self.small]?.unread,
                "Cmd-N's unread work grew with the workspace count: 8 -> \(costs[Self.small]?.description ?? "?"), 5,000 -> \(costs[Self.large]?.description ?? "?")")
        #expect((costs[Self.large]?.unread ?? .max) <= 1)
    }

    @Test func cmdDVisitsNoOtherWorkspacesUnreadCount() {
        var costs: [Int: Cost] = [:]
        for count in [Self.small, Self.large] {
            let store = Self.store(count)
            costs[count] = Self.cost(store) { Self.split($0, workspace: 0) }
            Self.expectConsistent(store, "after Cmd-D among \(count) workspaces")
        }
        #expect(costs[Self.large] == costs[Self.small],
                "Cmd-D's store work grew with the workspace count: 8 -> \(costs[Self.small]?.description ?? "?"), 5,000 -> \(costs[Self.large]?.description ?? "?")")
        #expect((costs[Self.large]?.unread ?? .max) <= 1)
    }

    /// A daemon batch while a Cmd-N is pending lifts the stand-in out of the list and puts it back: the lift's
    /// publication adds only what it changed, not every workspace.
    @Test func aBatchDuringAPendingCmdNVisitsOnlyWhatItChanged() {
        var costs: [Int: Cost] = [:]
        for count in [Self.small, Self.large] {
            let store = Self.store(count)
            Self.newWorkspace(store)
            costs[count] = Self.cost(store) {
                _ = $0.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .tabChanged(TabDelta(
                    workspace: Self.handle(2), screen: Self.screen(2), pane: Self.pane(2), surface: Self.surface(2), index: 0,
                    entity: Self.tab(2, unread: 11))))])
            }
            #expect(store.unreadBadge() == 1)
            Self.expectConsistent(store, "after a batch during a pending Cmd-N among \(count) workspaces")
        }
        #expect(costs[Self.large]?.unread == costs[Self.small]?.unread,
                "a batch during a pending Cmd-N: 8 -> \(costs[Self.small]?.description ?? "?"), 5,000 -> \(costs[Self.large]?.description ?? "?")")
    }

    /// A close takes its workspace's count out; the rest are not visited.
    @Test func aCloseVisitsOnlyTheClosedWorkspace() {
        var costs: [Int: Cost] = [:]
        for count in [Self.small, Self.large] {
            let store = Self.store(count)
            Self.notify(store, workspace: 5, id: 4)
            costs[count] = Self.cost(store) {
                _ = $0.apply(.workspaceClosed(WorkspaceDelta(workspace: Self.handle(5), index: nil, entity: Self.workspace(5), workspaceRevision: 2)))
            }
            #expect(store.unreadBadge() == 0)
            Self.expectConsistent(store, "after a close among \(count) workspaces")
        }
        #expect(costs[Self.large]?.unread == costs[Self.small]?.unread)
        #expect((costs[Self.large]?.unread ?? .max) <= 1)
    }

    /// The sidebar flattening walks the list once, whatever the number of groups (it walked it once per group, and
    /// scanned the groups for each workspace).
    @Test func theSidebarFlatteningWalksTheListOnce() {
        let store = Self.store(Self.large)
        let groups = (0..<Self.groups).map { index in
            WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: "g\(index)"), name: "g\(index)", index: index)
        }
        var workspaces = (0..<Self.large).map(Self.workspace)
        for index in workspaces.indices where index % 2 == 0 { workspaces[index].group = groups[index % Self.groups].id }
        let visits = store.sidebarWorkspaceVisits
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: workspaces, groups: groups))
        let walked = store.sidebarWorkspaceVisits - visits
        #expect(walked <= 2 * Self.large, "the flattening visited \(walked) workspaces for a list of \(Self.large) in \(Self.groups) groups")
        #expect(store.sidebarSections.count == Self.groups + 1)
        #expect(store.sidebarSections.reduce(0) { $0 + $1.workspaces.count } == Self.large)
    }
}
