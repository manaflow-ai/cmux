import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21 (ask-18a79e54a3): "A LOT OF THESE SESSIONS ID IMAGINE DIDNT NECESSSARILY NEED TO SHOW UP ON THE SIDE
/// BY DEFAULT". Lineage nesting is on by default: a workspace an agent started lists under the workspace whose agent
/// started it, at any depth; a parent below the top level starts folded behind a count. A Debug toggle
/// (`sidebar.lineageNesting`) turns it off.
@MainActor @Suite(.serialized) struct SidebarLineageNestingTests {
    private static let coordinator = WorkspaceID("coordinator"), lane = WorkspaceID("lane"), sub = WorkspaceID("sub")
    private static let reviewer = WorkspaceID("reviewer"), mine = WorkspaceID("mine")
    /// coordinator → lane → sub → reviewer, and `mine`, which a person started.
    private static let parents = [lane: coordinator, sub: lane, reviewer: sub]

    private static func sections(_ order: [WorkspaceID], done: Set<WorkspaceID> = []) -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: order.map { id in
            var ws = SidebarWorkspace(id: id, title: id.rawValue)
            if done.contains(id) { ws.taskStatus = .done }
            return .workspace(ws)
        })]
    }

    private static func rows(_ sections: [SidebarSection], tree: SidebarSessionTreeState?,
                             configure: (inout SidebarLayoutOptions) -> Void = { _ in }) -> [(id: WorkspaceID, content: WorkspaceRowContent)] {
        var o = SidebarLayoutOptions()
        o.sessionTree = tree
        configure(&o)
        return SidebarLayout.make(sections: sections, metrics: .standard, options: o).rows.compactMap { row in
            if case let .workspace(id) = row.key, let content = row.content { (id, content) } else { nil }
        }
    }

    /// The default: the coordinator and the person's own workspace are top level, the lane draws under the
    /// coordinator, and the lane's own sessions (depth 2 and 3) fold into its count.
    @Test func agentStartedSessionsNestAndFoldBelowDepthOne() {
        let tree = SidebarSessionTreeState(parents: Self.parents, foldsDeep: true)
        let drawn = Self.rows(Self.sections([Self.reviewer, Self.mine, Self.sub, Self.coordinator, Self.lane]), tree: tree)
        #expect(drawn.map(\.id) == [Self.mine, Self.coordinator, Self.lane])
        #expect(drawn.map(\.content.treeDepth) == [0, 0, 1])
        let byID = Dictionary(uniqueKeysWithValues: drawn.map { ($0.id, $0.content) })
        #expect(byID[Self.coordinator]?.treeFold == .expanded)
        #expect(byID[Self.lane]?.treeFold == .collapsed)
        // Two idle sessions under the lane: the count says 2 though neither has a state to show.
        #expect(byID[Self.lane]?.rollUp == SidebarTreeRollUp(total: 2))
        #expect(byID[Self.mine]?.treeFold == nil)
    }

    /// Opening the lane shows its sub-session at depth 2, itself folded over the reviewer at depth 3.
    @Test func openingADeepParentShowsOneMoreLevel() {
        var tree = SidebarSessionTreeState(parents: Self.parents, foldsDeep: true)
        tree.opened = [Self.lane]
        let drawn = Self.rows(Self.sections([Self.coordinator, Self.lane, Self.sub, Self.reviewer]), tree: tree)
        #expect(drawn.map(\.id) == [Self.coordinator, Self.lane, Self.sub])
        #expect(drawn.map(\.content.treeDepth) == [0, 1, 2])
        #expect(drawn.last?.content.treeFold == .collapsed)
        #expect(drawn.last?.content.rollUp?.total == 1)
        tree.opened = [Self.lane, Self.sub]
        let open = Self.rows(Self.sections([Self.coordinator, Self.lane, Self.sub, Self.reviewer]), tree: tree)
        #expect(open.map(\.content.treeDepth) == [0, 1, 2, 3])
        // The user folds the coordinator: everything under it rolls up.
        tree.collapsed = [Self.coordinator]
        let folded = Self.rows(Self.sections([Self.coordinator, Self.lane, Self.sub, Self.reviewer]), tree: tree)
        #expect(folded.map(\.id) == [Self.coordinator])
        #expect(folded.first?.content.rollUp?.total == 3)
    }

    /// A fold's state counts too: a waiting session two levels down shows on the lane's roll-up.
    @Test func aDeepFoldRollsUpItsStates() {
        let tree = SidebarSessionTreeState(parents: Self.parents, states: [Self.sub: .running, Self.reviewer: .blocked], foldsDeep: true)
        let lane = Self.rows(Self.sections([Self.coordinator, Self.lane, Self.sub, Self.reviewer]), tree: tree).first { $0.id == Self.lane }
        #expect(lane?.content.rollUp == SidebarTreeRollUp(blocked: 1, running: 1, total: 2))
    }

    /// Group members nest and fold the same way as a section's loose rows.
    @Test func groupMembersNestAtDepth() {
        let members = [Self.reviewer, Self.lane, Self.sub, Self.coordinator].map { SidebarWorkspace(id: $0, title: $0.rawValue) }
        let group = SidebarGroup(id: GroupID("g"), name: "GUI push", workspaces: members)
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.group(group)])]
        let drawn = Self.rows(sections, tree: SidebarSessionTreeState(parents: Self.parents, foldsDeep: true))
        #expect(drawn.map(\.id) == [Self.coordinator, Self.lane])
        #expect(drawn.map(\.content.treeDepth) == [0, 1])
        #expect(drawn.last?.content.treeFold == .collapsed)
    }

    /// A filter opens every fold, deep ones included.
    @Test func aFilterOpensDeepFolds() {
        let tree = SidebarSessionTreeState(parents: Self.parents, foldsDeep: true)
        let all = [Self.coordinator, Self.lane, Self.sub, Self.reviewer]
        let drawn = Self.rows(Self.sections(all), tree: tree) { $0.filterMatches = Set(all) }
        #expect(drawn.map(\.id) == all)
    }

    /// The Done fold with nesting: a Done top-level row takes its subtree into "Done (N)"; a Done lane stays under
    /// its parent, which is not Done.
    @Test func doneFoldMovesWholeRuns() {
        let tree = SidebarSessionTreeState(parents: [Self.lane: Self.coordinator], foldsDeep: true)
        let order = [Self.coordinator, Self.lane, Self.mine]
        let rootDone = Self.rows(Self.sections(order, done: [Self.coordinator]), tree: tree) { $0.foldsDone = true }
        #expect(rootDone.map(\.id) == [Self.mine])
        let laneDone = Self.rows(Self.sections(order, done: [Self.lane]), tree: tree) { $0.foldsDone = true }
        #expect(laneDone.map(\.id) == [Self.coordinator, Self.lane, Self.mine])
    }

    /// An idle-only subtree is not empty: its count chip draws.
    @Test func anIdleOnlyRollUpIsNotEmpty() {
        #expect(!SidebarTreeRollUp(total: 2).isEmpty)
        #expect(SidebarTreeRollUp().isEmpty)
        #expect(SidebarTreeRollUp([.idle, .idle]) == SidebarTreeRollUp(total: 2))
    }

    /// Lineage nesting alone (the tree state set, `sidebar.sessionTree` off) draws no keycaps.
    @Test func nestingAloneDrawsNoKeycaps() {
        SidebarSessionTree.shared.state = SidebarSessionTreeState(parents: [Self.lane: Self.coordinator])
        let savedTree = DesignSettings.shared.sidebarSections.sessionTree
        DesignSettings.shared.sidebarSections.sessionTree = false
        defer {
            SidebarSessionTree.shared.state = nil
            DesignSettings.shared.sidebarSections.sessionTree = savedTree
        }
        let sidebar = SidebarView(model: SidebarModel(sections: Self.sections([Self.coordinator, Self.lane])), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        let o = sidebar.list.options(includeGap: false)
        #expect(o.sessionTree != nil)
        #expect(o.keycaps.isEmpty)
        #expect(o.chatHistory == nil)
    }

    /// One workspace listed twice (lane, loose and in a group) nests by each list on its own: in the group, where
    /// its parent is absent, it is a root, so its child there is not hidden and the loose list's folds stay shut.
    @Test func aWorkspaceListedTwiceNestsPerList() {
        let group = SidebarGroup(id: GroupID("g"), name: "g", workspaces: [SidebarWorkspace(id: Self.lane, title: "lane"),
                                                                        SidebarWorkspace(id: Self.sub, title: "sub")])
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: Self.coordinator, title: "c")), .workspace(SidebarWorkspace(id: Self.lane, title: "l")), .group(group),
        ])])
        #expect(model.listsHolding(Self.lane).count == 2)
        #expect(model.listsHolding(Self.sub).count == 1)
        let defaults = UserDefaults(suiteName: "SidebarLineageNestingTests.\(UUID().uuidString)") ?? .standard
        let tree = SidebarSessionTree(defaults: defaults)
        tree.state = SidebarSessionTreeState(parents: [Self.lane: Self.coordinator, Self.sub: Self.lane])
        // In the group, sub draws under lane at depth 1, and lane is a root there (open): sub is visible.
        #expect(tree.drawn?.hidesInFold(Self.sub, lists: model.listsHolding(Self.sub)) == false)
        tree.reveal(Self.sub, lists: model.listsHolding(Self.sub))
        #expect(tree.opened.isEmpty && tree.collapsed.isEmpty)
    }

    /// The lineage arriving after the selection (the feed starts after restored windows) reveals the selection; a
    /// fold the person makes later (same parents) does not undo itself.
    @Test func lateLineageRevealsTheSelectionButAFoldStays() {
        let lineage = SidebarSessionTreeState(parents: Self.parents)
        #expect(SidebarView.revealsSelection(selectionChanged: false, from: nil, to: lineage))
        var folded = lineage
        folded.collapsed = [Self.coordinator]
        #expect(!SidebarView.revealsSelection(selectionChanged: false, from: lineage, to: folded))
        #expect(SidebarView.revealsSelection(selectionChanged: true, from: lineage, to: lineage))
        // Before the feed's first pass reveal does nothing; once the lineage is in, the same reveal opens the folds.
        let defaults = UserDefaults(suiteName: "SidebarLineageNestingTests.\(UUID().uuidString)") ?? .standard
        let tree = SidebarSessionTree(defaults: defaults)
        tree.reveal(Self.reviewer, lists: [{ _ in true }])
        #expect(tree.opened.isEmpty)
        tree.state = lineage
        tree.reveal(Self.reviewer, lists: [{ _ in true }])
        #expect(tree.opened == [Self.lane, Self.sub])
    }

    @Test func runsCutAtEachTopLevelEntry() {
        let runs = SidebarLayout.runs([(0, 0), (1, 1), (2, 2), (3, 0), (4, 1), (5, 0)])
        #expect(runs.map { $0.map(\.index) } == [[0, 1, 2], [3, 4], [5]])
    }

    /// The row's chevron toggles from what it draws: a deep parent starts folded, so its first press opens it.
    @Test func togglingADeepParentOpensItAndPersists() {
        let defaults = UserDefaults(suiteName: "SidebarLineageNestingTests.\(UUID().uuidString)") ?? .standard
        let tree = SidebarSessionTree(defaults: defaults)
        tree.state = SidebarSessionTreeState(parents: Self.parents)
        #expect(tree.drawn?.foldsDeep == true)
        #expect(tree.drawn?.isFolded(Self.lane, depth: 1) == true)
        tree.toggle(Self.lane, folded: true)
        #expect(tree.drawn?.isFolded(Self.lane, depth: 1) == false)
        #expect(SidebarSessionTree(defaults: defaults).opened == [Self.lane]) // the next launch
        tree.toggle(Self.lane, folded: false)
        #expect(tree.drawn?.isFolded(Self.lane, depth: 1) == true)
        #expect(tree.opened.isEmpty)
    }

    /// Selecting a session a deep fold hides opens the folds above it.
    @Test func revealOpensDeepAncestors() {
        let defaults = UserDefaults(suiteName: "SidebarLineageNestingTests.\(UUID().uuidString)") ?? .standard
        let tree = SidebarSessionTree(defaults: defaults)
        tree.state = SidebarSessionTreeState(parents: Self.parents)
        let oneList: [(WorkspaceID) -> Bool] = [{ _ in true }]
        #expect(tree.drawn?.hidesInFold(Self.reviewer, lists: oneList) == true)
        tree.reveal(Self.reviewer, lists: oneList)
        #expect(tree.opened == [Self.lane, Self.sub])
        #expect(tree.drawn?.hidesInFold(Self.reviewer, lists: oneList) == false)
    }

    /// A row whose parent sits in another list draws at the top level of its own list: no fold hides it, and
    /// selecting it opens nothing in the other list. A cycle nests nothing either.
    @Test func aParentInAnotherListOrACycleHidesAndOpensNothing() {
        let defaults = UserDefaults(suiteName: "SidebarLineageNestingTests.\(UUID().uuidString)") ?? .standard
        let tree = SidebarSessionTree(defaults: defaults)
        tree.state = SidebarSessionTreeState(parents: Self.parents)
        // sub is listed apart from lane (another group); lane and coordinator share a list.
        let list1: [(WorkspaceID) -> Bool] = [{ $0 == Self.sub || $0 == Self.reviewer }]
        #expect(tree.drawn?.hidesInFold(Self.sub, lists: list1) == false)
        tree.reveal(Self.sub, lists: list1)
        #expect(tree.opened.isEmpty)
        // The reviewer draws under sub, a root of list 1: sub is open at depth 0, so nothing hides it.
        #expect(tree.drawn?.hidesInFold(Self.reviewer, lists: list1) == false)
        let x = WorkspaceID("x"), y = WorkspaceID("y")
        tree.state = SidebarSessionTreeState(parents: [x: y, y: x])
        #expect(tree.drawn?.hidesInFold(x, lists: [{ _ in true }]) == false)
        tree.reveal(x, lists: [{ _ in true }])
        #expect(tree.opened.isEmpty && tree.collapsed.isEmpty)
    }

    /// The Debug toggle: on by default; off, the feed's tree keeps no parents, so every workspace is top level,
    /// while `sidebar.sessionTree`'s other parts still show. Nesting alone asks GitHub nothing.
    @Test func theToggleTurnsNestingOff() {
        #expect(SidebarTunables.lineageNesting.defaultValue == true)
        #expect(SidebarTunables.all.contains { $0.key == SidebarTunables.lineageNesting.key })
        let pass = SidebarSessionTreeFeed.Pass(state: SidebarSessionTreeState(parents: Self.parents), asks: [])
        let nesting = SidebarSessionTreeFeed.shaped(pass, sessionTree: false, nests: true, reads: false)
        #expect(nesting.showsTree && !nesting.readsPullRequests)
        #expect(nesting.state.parents == Self.parents)
        let off = SidebarSessionTreeFeed.shaped(pass, sessionTree: true, nests: false, reads: true)
        #expect(off.showsTree && off.readsPullRequests)
        #expect(off.state.parents.isEmpty)
        let flat = Self.rows(Self.sections([Self.reviewer, Self.coordinator, Self.lane]), tree: off.state)
        #expect(flat.map(\.id) == [Self.reviewer, Self.coordinator, Self.lane])
    }
}
