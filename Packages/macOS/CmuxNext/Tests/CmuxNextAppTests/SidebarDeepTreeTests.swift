@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-18: "there's literally only 1 level of nesting/grouping so everything literally goes
/// under you even tho new sessions start their own new sessions". With `sidebar.sessionTree` on, each
/// workspace draws at its real depth in the spawn tree (who started whom), right after its parent and
/// before its parent's next sibling, however deep the tree runs.
@MainActor @Suite(.serialized) struct SidebarDeepTreeTests {
    @Test func treeOrderDrawsEveryLevelAtItsDepth() {
        let a = WorkspaceID("a"), b = WorkspaceID("b"), c = WorkspaceID("c"), d = WorkspaceID("d"), far = WorkspaceID("far")
        // c under b under a. d's parent is in another list: d stays a root.
        let order = SidebarLayout.treeOrder([c, nil, a, d, b], parents: [b: a, c: b, d: far])
        #expect(order.map { $0.index } == [1, 2, 4, 0, 3])
        #expect(order.map { $0.depth } == [0, 0, 1, 2, 0])
    }

    @Test func siblingsKeepTheirOwnOrderUnderTheirParent() {
        let root = WorkspaceID("root"), x = WorkspaceID("x"), y = WorkspaceID("y"), x1 = WorkspaceID("x1")
        // Model order: y before x; x1 under x. Siblings keep the model's order.
        let order = SidebarLayout.treeOrder([root, y, x1, x], parents: [y: root, x: root, x1: x])
        #expect(order.map { $0.index } == [0, 1, 3, 2])
        #expect(order.map { $0.depth } == [0, 1, 1, 2])
    }

    /// Fifty workspaces, five coordinators, children up to four levels down: each row draws at its
    /// depth, and every subtree is one unbroken run right under its root.
    @Test func fiftySessionsFourLevelsDeepDrawAsATree() {
        let tree = Self.fiftySessionTree()
        let drawn = SidebarLayout.treeOrder(tree.ids.map(Optional.some), parents: tree.parents)
        #expect(drawn.count == 50)
        for (index, depth) in drawn {
            #expect(depth == tree.depth[tree.ids[index]], "\(tree.ids[index]) draws at its depth")
        }
        let positions = Dictionary(uniqueKeysWithValues: drawn.enumerated().map { (tree.ids[$0.element.index], $0.offset) })
        for (child, parent) in tree.parents {
            let at = positions[child] ?? -1, parentAt = positions[parent] ?? -1
            #expect(at > parentAt, "\(child) draws after its parent")
            // Everything between the parent and the child is deeper than the parent: one subtree.
            for between in drawn[(parentAt + 1)..<at] {
                #expect((tree.depth[tree.ids[between.index]] ?? 0) > (tree.depth[parent] ?? 0))
            }
        }
        #expect(tree.depth.values.max() == 4)
    }

    @Test func aFoldedParentHidesItsWholeSubtree() {
        let a = WorkspaceID("a"), b = WorkspaceID("b"), c = WorkspaceID("c"), d = WorkspaceID("d")
        let order = SidebarLayout.treeOrder([c, nil, a, d, b], parents: [b: a, c: b], collapsed: [b])
        #expect(order.map { $0.index } == [1, 2, 4, 3])
        #expect(order.map { $0.depth } == [0, 0, 1, 0])
    }

    /// a started b and e; b started c and d. Folding a rolls up everything under it, by state.
    @Test func aFoldedParentRollsUpWhatItsSessionsAreDoing() {
        let ids = ["a", "b", "c", "d", "e"].map(WorkspaceID.init)
        let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        var finished = SidebarWorkspace(id: d, title: "d")
        finished.unread = .dot
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: a, title: "a")), .workspace(SidebarWorkspace(id: b, title: "b")),
            .workspace(SidebarWorkspace(id: c, title: "c")), .workspace(finished), .workspace(SidebarWorkspace(id: e, title: "e")),
        ])]
        var tree = SidebarSessionTreeState(parents: [b: a, c: b, d: b, e: a], states: [b: .running, c: .blocked, d: .idle, e: .failed])
        func rows() -> [WorkspaceID: WorkspaceRowContent] {
            var options = SidebarLayoutOptions()
            options.sessionTree = tree
            return Dictionary(uniqueKeysWithValues: SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows.compactMap { row in
                if case let .workspace(id) = row.key, let content = row.content { (id, content) } else { nil }
            })
        }
        let open = rows()
        #expect(open.count == 5)
        #expect(open[a]?.treeFold == .expanded)
        #expect(open[b]?.treeFold == .expanded)
        #expect(open[c]?.treeFold == nil)
        #expect(open[a]?.rollUp == nil)
        tree.collapsed = [a]
        let folded = rows()
        #expect(Set(folded.keys) == [a])
        #expect(folded[a]?.treeFold == .collapsed)
        // d is idle by its lane but unread: finished, unread. An idle descendant is in no state's count, only the total.
        #expect(folded[a]?.rollUp == SidebarTreeRollUp(blocked: 1, failed: 1, running: 1, unread: 1, total: 4))
    }

    /// A filter opens every fold (search finds a session a fold hides), so a folded parent that
    /// matches draws open: no collapsed chevron and no roll-up above its own children.
    @Test func aFilterDrawsAFoldedParentOpen() {
        let a = WorkspaceID("a"), b = WorkspaceID("b")
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: a, title: "a")), .workspace(SidebarWorkspace(id: b, title: "b")),
        ])]
        var options = SidebarLayoutOptions()
        options.sessionTree = SidebarSessionTreeState(parents: [b: a], states: [b: .blocked], collapsed: [a])
        options.filterMatches = [a, b]
        let rows = Dictionary(uniqueKeysWithValues: SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows.compactMap { row in
            if case let .workspace(id) = row.key, let content = row.content { (id, content) } else { nil }
        })
        #expect(Set(rows.keys) == [a, b])
        #expect(rows[a]?.treeFold == .expanded)
        #expect(rows[a]?.rollUp == nil)
    }

    /// A long chain resolves in one pass: every node finds its root once, not once per ancestor.
    @Test func treeChildrenOfADeepChainKeepsEveryLink() {
        let ids = (0..<2000).map { WorkspaceID("c\($0)") }
        var parents: [WorkspaceID: WorkspaceID] = [:]
        for n in 1..<ids.count { parents[ids[n]] = ids[n - 1] }
        let children = SidebarLayout.treeChildren(ids.map(Optional.some), parents: parents)
        #expect(children.count == ids.count - 1)
        #expect(children[ids[0]] == [1])
        // A cycle hanging off the chain stays rootless.
        let x = WorkspaceID("x"), y = WorkspaceID("y")
        let cyclic = SidebarLayout.treeChildren([ids[0], x, y], parents: [x: y, y: x])
        #expect(cyclic.isEmpty)
    }

    @Test func aWorkspaceWithoutALaneReadsItsRowStrictly() {
        var ws = SidebarWorkspace(id: WorkspaceID("w"), title: "w")
        #expect(SidebarAgentState.of(ws, lane: nil) == .idle)
        ws.unread = .count(3)
        #expect(SidebarAgentState.of(ws, lane: nil) == .finishedUnread) // unread alone never waits on you
        ws.activity = .waiting
        #expect(SidebarAgentState.of(ws, lane: nil) == .blocked)
        ws.activity = .error
        #expect(SidebarAgentState.of(ws, lane: nil) == .failed)
        // A lane decides: a coordinator idle while its children run is idle, whatever its row says.
        ws.activity = .waiting
        ws.unread = .none
        #expect(SidebarAgentState.of(ws, lane: .idle) == .idle)
        #expect(SidebarAgentState.of(ws, lane: .running) == .running)
    }

    @Test func aFoldSurvivesTheFeedsNextPass() {
        let defaults = UserDefaults(suiteName: "SidebarDeepTreeTests.\(UUID().uuidString)") ?? .standard
        let tree = SidebarSessionTree(defaults: defaults)
        let a = WorkspaceID("a")
        tree.state = SidebarSessionTreeState(parents: [WorkspaceID("b"): a])
        tree.toggle(a)
        tree.state = SidebarSessionTreeState(parents: [WorkspaceID("b"): a, WorkspaceID("c"): a]) // the feed passes again
        #expect(tree.drawn?.collapsed == [a])
        #expect(SidebarSessionTree(defaults: defaults).collapsed == [a]) // and the next launch
        tree.toggle(a)
        #expect(tree.drawn?.collapsed == [])
    }

    /// The saved folds keep only parents the tree still has: a closed workspace's fold leaves the
    /// list on the next save, so it never grows with every workspace ever folded. Before the
    /// feed's first pass (no parents yet) nothing is dropped.
    @Test func aClosedParentsFoldLeavesTheSavedList() {
        let defaults = UserDefaults(suiteName: "SidebarDeepTreeTests.\(UUID().uuidString)") ?? .standard
        let tree = SidebarSessionTree(defaults: defaults)
        let a = WorkspaceID("a"), b = WorkspaceID("b"), d = WorkspaceID("d")
        tree.state = SidebarSessionTreeState(parents: [WorkspaceID("child-a"): a, WorkspaceID("child-d"): d])
        tree.toggle(a)
        tree.toggle(d)
        tree.state = SidebarSessionTreeState(parents: [WorkspaceID("child-d"): d, WorkspaceID("child-b"): b]) // a closed
        tree.toggle(b)
        #expect(tree.collapsed == [b, d])
        #expect(Set(defaults.stringArray(forKey: SidebarSessionTree.collapsedKey) ?? []) == ["b", "d"])
        let launched = SidebarSessionTree(defaults: defaults)
        launched.toggle(WorkspaceID("e")) // before the first pass
        #expect(launched.collapsed == [b, d, WorkspaceID("e")])
    }

    /// Revealing a selected session opens only the folds above it. At launch the feed's first
    /// passes may not know every parent yet, so a reveal never drops another saved fold.
    @Test func aRevealOpensOnlyTheFoldsAboveItAndKeepsTheRest() {
        let defaults = UserDefaults(suiteName: "SidebarDeepTreeTests.\(UUID().uuidString)") ?? .standard
        let a = WorkspaceID("a"), b = WorkspaceID("b"), d = WorkspaceID("d"), c = WorkspaceID("c")
        defaults.set(["a", "b", "d"], forKey: SidebarSessionTree.collapsedKey)
        let tree = SidebarSessionTree(defaults: defaults)
        tree.state = SidebarSessionTreeState(parents: [b: a, c: b]) // d's lane hasn't loaded yet
        tree.reveal(c, lists: [{ _ in true }])
        #expect(tree.collapsed == [d])
        #expect(defaults.stringArray(forKey: SidebarSessionTree.collapsedKey) == ["d"])
    }

    /// A fixed fifty-workspace spawn tree: `w0`...`w4` are coordinators; `w<n>` for n >= 5 was
    /// started by an earlier workspace, chosen so the tree is four levels deep. Model order is the
    /// ids' order shuffled by a fixed stride, so drawn order cannot follow model order by chance.
    static func fiftySessionTree() -> (ids: [WorkspaceID], parents: [WorkspaceID: WorkspaceID], depth: [WorkspaceID: Int]) {
        var parents: [WorkspaceID: WorkspaceID] = [:]
        var depth: [WorkspaceID: Int] = [:]
        let all = (0..<50).map { WorkspaceID("w\($0)") }
        for n in 0..<5 { depth[all[n]] = 0 }
        for n in 5..<50 {
            // Walk candidates from n-5 down; take the first that keeps depth at most 4.
            var parent = n - 5
            while (depth[all[parent]] ?? 0) >= 4 { parent -= 1 }
            parents[all[n]] = all[parent]
            depth[all[n]] = (depth[all[parent]] ?? 0) + 1
        }
        let ids = (0..<50).map { all[($0 * 17) % 50] }
        return (ids, parents, depth)
    }
}
