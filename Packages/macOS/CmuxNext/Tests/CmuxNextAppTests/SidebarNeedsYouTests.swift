@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-18: the sidebar "still doesn't surface what actually needs him". With
/// `sidebar.sessionTree` on, a fixed tray lists only what is blocked on you (a question or a
/// permission, a failure) with the path to it, and counts finished sessions you have not read.
/// Running, idle and merely unread sessions never enter it; a coordinator waiting on its own
/// children is not waiting on you. It reads the same however the rows were dragged.
@MainActor @Suite(.serialized) struct SidebarNeedsYouTests {
    private static func section(_ workspaces: [SidebarWorkspace]) -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: workspaces.map(SidebarNode.workspace))]
    }

    /// Fifty sessions, four levels deep, every state there is: the tray lists exactly the blocked
    /// and failed ones, in the tree's drawn order, and counts the finished unread ones.
    @Test func theTrayListsOnlyWhatIsBlockedOnYou() {
        let tree = SidebarDeepTreeTests.fiftySessionTree()
        var lanes: [WorkspaceID: SidebarAgentState] = [:]
        var workspaces: [SidebarWorkspace] = []
        let cycle: [SidebarAgentState?] = [.blocked, .running, .idle, .failed, .finishedUnread, nil, .running, .idle]
        for (n, id) in tree.ids.enumerated() {
            var ws = SidebarWorkspace(id: id, title: id.rawValue)
            switch cycle[n % cycle.count] {
            case .finishedUnread?: lanes[id] = .idle; ws.unread = .dot
            case let state?: lanes[id] = state
            case nil: ws.unread = .count(2); ws.activity = .success // no lane, unread: finished, not blocked
            }
            workspaces.append(ws)
        }
        let state = SidebarSessionTreeState(parents: tree.parents, states: lanes)
        let tray = SidebarNeedsYou.make(Self.section(workspaces), tree: state)
        let expected = Set(lanes.filter { $0.value == .blocked || $0.value == .failed }.keys)
        #expect(Set(tray.items.map(\.id)) == expected)
        #expect(tray.items.count == expected.count)
        #expect(tray.unread == workspaces.filter { $0.unread.isUnread }.count)
        // In the order the tree draws them, so the tray never reshuffles on its own either.
        let drawn = SidebarLayout.treeOrder(tree.ids.map(Optional.some), parents: tree.parents).map { tree.ids[$0.index] }
        #expect(tray.items.map(\.id) == drawn.filter(expected.contains))
        for item in tray.items {
            #expect(item.reason == (lanes[item.id] == .failed ? .failed : .waiting))
        }
    }

    @Test func anItemNamesThePathToItAndAFoldedParentDoesNotHideIt() throws {
        let root = WorkspaceID("root"), mid = WorkspaceID("mid"), leaf = WorkspaceID("leaf")
        let workspaces = [SidebarWorkspace(id: root, title: "Release week"), SidebarWorkspace(id: mid, title: "Settings pass"),
                          SidebarWorkspace(id: leaf, title: "Shrink large files")]
        let state = SidebarSessionTreeState(parents: [mid: root, leaf: mid], states: [root: .idle, mid: .idle, leaf: .blocked],
                                            collapsed: [root])
        let tray = SidebarNeedsYou.make(Self.section(workspaces), tree: state)
        let item = try #require(tray.items.first)
        #expect(tray.items.count == 1)
        #expect(item.title == "Shrink large files")
        #expect(item.path == ["Release week", "Settings pass"])
    }

    @Test func aRowWithoutALaneIsBlockedOnlyWhenItSaysItWaits() {
        var waiting = SidebarWorkspace(id: WorkspaceID("w"), title: "w")
        waiting.activity = .waiting
        var unread = SidebarWorkspace(id: WorkspaceID("u"), title: "u")
        unread.unread = .count(5)
        var failed = SidebarWorkspace(id: WorkspaceID("f"), title: "f")
        failed.activity = .error
        let tray = SidebarNeedsYou.make(Self.section([unread, waiting, failed]), tree: SidebarSessionTreeState())
        #expect(tray.items.map(\.id) == [WorkspaceID("w"), WorkspaceID("f")])
        #expect(tray.unread == 1)
    }

    @Test func withoutTheTreeTheTrayIsEmpty() {
        var waiting = SidebarWorkspace(id: WorkspaceID("w"), title: "w")
        waiting.activity = .waiting
        #expect(SidebarNeedsYou.make(Self.section([waiting]), tree: nil) == SidebarNeedsYou())
    }

    /// The tray reads the same however the rows were dragged: a drag moves rows, never the tray.
    @Test func theTrayIsTheSameInAnyRowOrder() {
        let tree = SidebarDeepTreeTests.fiftySessionTree()
        let workspaces = tree.ids.map { SidebarWorkspace(id: $0, title: $0.rawValue) }
        var lanes: [WorkspaceID: SidebarAgentState] = [:]
        for (n, id) in tree.ids.enumerated() { lanes[id] = n % 3 == 0 ? .blocked : .running }
        let state = SidebarSessionTreeState(parents: tree.parents, states: lanes)
        let stable = SidebarNeedsYou.make(Self.section(workspaces), tree: state)
        // Drag the blocked rows first in the list; the tray keeps the tree's order.
        let blocked = workspaces.filter { lanes[$0.id] == .blocked }
        let lifted = blocked + workspaces.filter { lanes[$0.id] != .blocked }
        let liftedIDs: Set<WorkspaceID> = Set(SidebarNeedsYou.make(Self.section(lifted), tree: state).items.map(\.id))
        let stableIDs: Set<WorkspaceID> = Set(stable.items.map(\.id))
        #expect(liftedIDs == stableIDs)
        #expect(stable.items.count == 17)
    }

    /// The capture fixture (`debug.sidebar_nested_fixture needsYou`) shows every kind of item.
    @Test func theCaptureFixtureShowsEveryKindOfItem() {
        let fixture = SidebarNestedFixture(scenario: .needsYou)
        let tray = SidebarNeedsYou.make(fixture.sections, tree: SidebarSessionTreeState(parents: fixture.parents))
        #expect(tray.items.map(\.title) == ["Shrink large files", "Changelog", "Flaky test hunt", "Cloud sign-in"])
        #expect(tray.items.first?.path == ["Release week", "Settings pass"])
        #expect(tray.unread == 2)
    }

    @Test func revealingAnItemOpensEveryFoldAboveIt() {
        let defaults = UserDefaults(suiteName: "SidebarNeedsYouTests.\(UUID().uuidString)") ?? .standard
        let tree = SidebarSessionTree(defaults: defaults)
        let root = WorkspaceID("root"), mid = WorkspaceID("mid"), leaf = WorkspaceID("leaf")
        let other = WorkspaceID("other"), otherChild = WorkspaceID("other-child")
        // `other` is a parent too: the tree keeps only folds of live parents.
        tree.state = SidebarSessionTreeState(parents: [mid: root, leaf: mid, otherChild: other])
        tree.toggle(root)
        tree.toggle(mid)
        tree.toggle(other)
        tree.reveal(leaf, lists: [{ _ in true }])
        #expect(tree.collapsed == [other])
    }
}
