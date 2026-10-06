import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSidebar
import Testing

/// Groups placed among the loose workspaces (`personal-mixed-order-v1`):
/// a group with a `top_index` shows right before that personal row, the
/// numbering and the window order follow what the sidebar shows, and the
/// daemon without the capability keeps the old order (loose rows, then
/// groups). Windows are never put on screen.
@MainActor
struct SidebarMixedOrderTests {
    static let keys = (1...4).map { WorkspaceKey(rawValue: "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6\($0)") }
    nonisolated static let session = "33333333-4444-4555-8666-777777777777"
    static let group: WorkspaceGroupID = "grp_g"

    private static func id(_ index: Int) -> String { keys[index - 1].rawValue }

    /// Rows w1...w4 at personal indices 0...3; G (default room) holds w3
    /// and shows before index 1.
    private static func services(mixed: Bool, collapsed: Bool = false) -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let snapshots = keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: key, name: "w\(index + 1)")
        }
        var tree = DaemonTree(registryID: session, workspaceRevision: 100, workspaces: snapshots)
        tree.personal = PersonalState(
            revision: 1,
            profiles: [ProfileSnapshot(id: .defaultProfile, name: "default", index: 0, follows: [session])],
            groups: [WorkspaceGroupSnapshot(id: group, name: "G", collapsed: collapsed, index: 0, topIndex: 1)],
            workspaces: keys.enumerated().map { index, key in
                PersonalWorkspace(sessionID: session, workspaceKey: key, index: index, group: index == 2 ? group : nil)
            })
        let store = services.daemon.store
        if mixed {
            store.noteHandshake(DaemonIdentity(capabilities: [DaemonCapabilities.shared.personalMixedOrder], generation: "g1"))
        }
        store.apply(snapshot: tree)
        return services
    }

    private static func label(_ workspace: WorkspaceModel) -> String {
        workspace.key.flatMap { keys.firstIndex(of: $0) }.map { "w\($0 + 1)" } ?? workspace.id
    }

    /// Loose rows by label, groups as `G[w3]`.
    private static func shape(_ sections: [CmuxNextDaemon.SidebarSection]) -> String {
        sections.flatMap { section -> [String] in
            guard let group = section.group else { return section.workspaces.map(label) }
            return ["\(group.name)[\(section.workspaces.map(label).joined(separator: ","))]"]
        }.joined(separator: " ")
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test(arguments: [true, false])
    func aGroupWithATopIndexShowsBetweenLooseRows(mixed: Bool) {
        let services = Self.services(mixed: mixed)
        let sections = PersonalSidebar.sections(of: services.machines.local, room: .defaultProfile, machines: services.machines)
        #expect(Self.shape(sections) == (mixed ? "w1 G[w3] w2 w4" : "w1 w2 w4 G[w3]"))
    }

    @Test(arguments: [false, true])
    func cmdDigitNumbersAGroupBetweenRowsAfterTheTopItems(collapsed: Bool) async throws {
        let services = Self.services(mixed: true, collapsed: collapsed)
        let window = try #require(services.windows.openWindow(workspaces: Self.keys.map(\.rawValue)))
        defer { window.window?.close() }
        let model = window.sidebar.model
        let rows = (collapsed ? [1, 2, 4] : [1, 3, 2, 4]).map(Self.id)
        await Self.settle { model.visibleWorkspaceIDs == rows }
        let first = model.layout.firstTopItem(room: model.activeProfileID?.rawValue)?.id
        let numbering = SidebarNumbering(firstTopItem: first, workspaces: model.visibleWorkspaceIDs)
        let top = first.map { [SidebarNumbering.Target.topItem($0)] } ?? []
        #expect(numbering.order == top + rows.map(SidebarNumbering.Target.workspace))
        // The first workspace number follows the top item: w1, then w3 inside G.
        #expect(numbering.pick(top.count + 1) == .workspace(Self.id(1)))
        #expect(numbering.pick(top.count + 2) == .workspace(Self.id(collapsed ? 2 : 3)))
    }

    @Test func theWindowOrderIsTheShownOrder() {
        let services = Self.services(mixed: true)
        let expected = [1, 3, 2, 4].map(Self.id)
        #expect(PersonalSidebar.orderedIDs(of: services.machines.local, machines: services.machines) == expected)
        #expect(WindowManager.orderedIDs(of: services.machines.local, machines: services.machines) == expected)
    }
}

/// What a group move or a workspace drop sends in the mixed order
/// (`top_index`, `workspace_group.move`, `workspace.place`).
@MainActor
struct MixedOrderPlacementTests {
    typealias Node = PersonalSidebar.MixedNode
    static let a: WorkspaceGroupID = "grp_a"
    static let b: WorkspaceGroupID = "grp_b"
    static let c: WorkspaceGroupID = "grp_c"
    /// Group order A (before row 1), B (after every loose row), C (before row 3).
    static let groups = [PersonalSidebar.MixedGroup(id: a, topIndex: 1), .init(id: b, topIndex: nil), .init(id: c, topIndex: 3)]

    private static func place(_ group: WorkspaceGroupID, after previous: Node?, before follower: Node?,
                              mixed: Bool = true) -> PersonalSidebar.GroupPlacement {
        PersonalSidebar.groupPlacement(group, previous: previous, follower: follower, groups: groups, rows: 6, home: 0, mixed: mixed)
    }

    @Test func aGroupBeforeALooseRowTakesThatRowsIndex() {
        #expect(Self.place(Self.a, after: .workspace(row: 3), before: .workspace(row: 4)) == .init(topIndex: .set(4), move: nil))
        // Before a row another group shows before too: after that group in group order.
        #expect(Self.place(Self.a, after: .group(Self.c), before: .workspace(row: 3)) == .init(topIndex: .set(3), move: 3))
        #expect(Self.place(Self.b, after: .group(Self.a), before: .workspace(row: 1)) == .init(topIndex: .set(1), move: nil))
    }

    @Test func aGroupBeforeAnotherGroupSharesItsPlaceAndPrecedesIt() {
        #expect(Self.place(Self.c, after: nil, before: .group(Self.a)) == .init(topIndex: .set(1), move: 0))
    }

    @Test func aGroupAtTheEndClearsItsPlaceAndFollowsTheOtherEndGroups() {
        #expect(Self.place(Self.a, after: .group(Self.c), before: nil) == .init(topIndex: .clear, move: 2))
    }

    @Test func theHomeRowAndRowlessWorkspacesNeverNameAPlace() {
        // At or before the home row is refused (home.pinned_first): the next row.
        #expect(Self.place(Self.a, after: nil, before: .workspace(row: 0)).topIndex == .set(1))
        // A workspace without a personal row cannot be named: the end.
        #expect(Self.place(Self.a, after: .workspace(row: 2), before: .workspace(row: nil)).topIndex == .clear)
    }

    @Test func withoutTheCapabilityOnlyTheGroupOrderMoves() {
        // The node index is not a group-order index: C before A is group index 0.
        #expect(Self.place(Self.c, after: .workspace(row: 2), before: .group(Self.a), mixed: false) == .init(topIndex: .unchanged, move: 0))
        #expect(Self.place(Self.a, after: .group(Self.c), before: nil, mixed: false) == .init(topIndex: .unchanged, move: 3))
    }

    @Test func aWorkspaceDroppedBeforeAGroupTakesTheGroupsRow() {
        let rows = ["h", "a", "b", "c", "d"]
        #expect(PersonalSidebar.anchorIndex(top: 2, rows: rows, moving: ["d"]) == 2)
        // The group's own row moves away: the next row that stays.
        #expect(PersonalSidebar.anchorIndex(top: 1, rows: rows, moving: ["a"]) == 1)
        #expect(PersonalSidebar.anchorIndex(top: nil, rows: rows, moving: ["a"]) == 4)
        #expect(PersonalSidebar.anchorIndex(top: 9, rows: rows, moving: []) == 5)
    }

    @Test func aWorkspaceDroppedRightAfterAGroupKeepsTheGroupBeforeIt() {
        // Rows h a b c d; A holds c and shows before b (index 2); d moves.
        let rows = ["h", "a", "b", "c", "d"]
        let groups = [PersonalSidebar.MixedGroup(id: Self.a, topIndex: 2)]
        let nodes: [Node] = [.workspace(row: 1), .group(Self.a), .workspace(row: 2)]
        let drop = { (slot: Int) in PersonalSidebar.mixedDrop(nodes: nodes, slot: slot, groups: groups, rows: rows, moving: ["d"]) }
        #expect(drop(1) == .init(index: 2, regroup: []))
        #expect(drop(2) == .init(index: nil, regroup: [Self.a]))
        #expect(drop(3) == .init(index: nil, regroup: []))
    }
}
