import Foundation
import Testing
@testable import CmuxSurfaceCatalogModel

/// A daemon screen that applies planner steps with the daemon's documented rules:
/// `tab.move` removes a pane that loses its last tab, `pane.split` adds a pane with a
/// fresh terminal, and `workspace.layout.apply` requires exact pane and split membership.
private struct FakeDaemonScreen {
    indirect enum Node: Equatable {
        case leaf(pane: String, tabs: [String], active: String?)
        case split(id: String, horizontal: Bool, ratio: Double, first: Node, second: Node)
    }

    var root: Node
    var nextID = 0
    var closedTerminals: [String] = []
    var mutations = 0

    var snapshot: [String: Any] {
        [
            "cursor": ["generation": "g", "revision": String(mutations)],
            "workspaces": [["id": "ws", "name": "ws"]],
            "screens": [["id": "scr", "workspace_id": "ws", "layout": [
                "version": 1, "screen_id": "scr", "active_pane_id": leaves.first?.pane ?? "",
                "zoomed_pane_id": NSNull(), "root": Self.json(root),
            ]]],
            "panes": leaves.map { ["id": $0.pane, "screen_id": "scr"] },
            "tabs": leaves.flatMap { leaf in
                leaf.tabs.map { ["id": $0, "pane_id": leaf.pane, "content_kind": "terminal", "content_id": "term_" + $0] }
            },
        ]
    }

    var leaves: [(pane: String, tabs: [String])] { Self.leaves(root) }

    static func leaves(_ node: Node) -> [(pane: String, tabs: [String])] {
        switch node {
        case .leaf(let pane, let tabs, _): return [(pane, tabs)]
        case .split(_, _, _, let first, let second): return leaves(first) + leaves(second)
        }
    }

    static func splitIDs(_ node: Node) -> Set<String> {
        guard case .split(let id, _, _, let first, let second) = node else { return [] }
        return Set([id]).union(splitIDs(first)).union(splitIDs(second))
    }

    static func json(_ node: Node) -> [String: Any] {
        switch node {
        case .leaf(let pane, let tabs, let active):
            var object: [String: Any] = ["kind": "leaf", "pane_id": pane, "tab_ids": tabs]
            if let active { object["active_tab_id"] = active }
            return object
        case .split(let id, let horizontal, let ratio, let first, let second):
            return ["kind": "split", "split_id": id, "direction": horizontal ? "horizontal" : "vertical",
                    "ratio": ratio, "first": json(first), "second": json(second)]
        }
    }

    static func node(_ object: [String: Any]) -> Node {
        if object["kind"] as? String == "leaf" {
            return .leaf(pane: object["pane_id"] as! String, tabs: object["tab_ids"] as! [String],
                         active: object["active_tab_id"] as? String)
        }
        return .split(id: object["split_id"] as! String, horizontal: object["direction"] as? String == "horizontal",
                      ratio: (object["ratio"] as! NSNumber).doubleValue,
                      first: node(object["first"] as! [String: Any]), second: node(object["second"] as! [String: Any]))
    }

    /// Removes `tab` wherever it is, collapsing a pane left empty into its sibling.
    static func removing(_ tab: String, from node: Node) -> Node? {
        switch node {
        case .leaf(let pane, var tabs, let active):
            tabs.removeAll { $0 == tab }
            return tabs.isEmpty ? nil : .leaf(pane: pane, tabs: tabs, active: active == tab ? tabs.first : active)
        case .split(let id, let horizontal, let ratio, let first, let second):
            switch (removing(tab, from: first), removing(tab, from: second)) {
            case let (first?, second?): return .split(id: id, horizontal: horizontal, ratio: ratio, first: first, second: second)
            case let (only?, nil), let (nil, only?): return only
            case (nil, nil): return nil
            }
        }
    }

    static func inserting(_ tab: String, into target: String, at index: Int, _ node: Node) -> Node {
        switch node {
        case .leaf(let pane, var tabs, let active):
            guard pane == target else { return node }
            tabs.insert(tab, at: min(index, tabs.count))
            return .leaf(pane: pane, tabs: tabs, active: active)
        case .split(let id, let horizontal, let ratio, let first, let second):
            return .split(id: id, horizontal: horizontal, ratio: ratio,
                          first: inserting(tab, into: target, at: index, first),
                          second: inserting(tab, into: target, at: index, second))
        }
    }

    static func splitting(_ target: String, newPane: String, tab: String, split: String, _ node: Node) -> Node {
        switch node {
        case .leaf(let pane, _, _):
            guard pane == target else { return node }
            return .split(id: split, horizontal: true, ratio: 0.5, first: node,
                          second: .leaf(pane: newPane, tabs: [tab], active: tab))
        case .split(let id, let horizontal, let ratio, let first, let second):
            return .split(id: id, horizontal: horizontal, ratio: ratio,
                          first: splitting(target, newPane: newPane, tab: tab, split: split, first),
                          second: splitting(target, newPane: newPane, tab: tab, split: split, second))
        }
    }

    /// Performs one step; returns the scratch tab a split created.
    mutating func perform(_ step: CloudLayoutSyncStep) throws -> String? {
        mutations += 1
        switch step {
        case .moveTab(let tab, let target):
            let source = try #require(leaves.first { $0.tabs.contains(tab) })
            let old = try #require(source.tabs.firstIndex(of: tab))
            // Same-pane indexes name the insertion point before removal, as in the daemon.
            let index = source.pane == target.paneID && target.index > old ? target.index - 1 : target.index
            try #require(leaves.contains { $0.pane == target.paneID })
            root = try #require(Self.removing(tab, from: root))
            try #require(leaves.contains { $0.pane == target.paneID }, "tab.move emptied its own destination")
            root = Self.inserting(tab, into: target.paneID, at: index, root)
            return nil
        case .splitPane(let pane):
            nextID += 1
            let tab = "scratch\(nextID)"
            root = Self.splitting(pane, newPane: "pane_new\(nextID)", tab: tab, split: "split_new\(nextID)", root)
            return tab
        case .closeScratch(let tab, let terminal):
            closedTerminals.append(terminal)
            root = try #require(Self.removing(tab, from: root))
            return nil
        case .applyLayout(let data):
            let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let next = Self.node(try #require(document["root"] as? [String: Any]))
            #expect(Set(Self.leaves(next).map(\.pane)) == Set(leaves.map(\.pane)), "pane membership must match")
            #expect(Self.splitIDs(next) == Self.splitIDs(root), "split membership must match")
            #expect(Set(Self.leaves(next).flatMap(\.tabs)) == Set(leaves.flatMap(\.tabs)), "tab membership must match")
            root = next
            return nil
        case .done, .notReady, .unsupported:
            Issue.record("Unexpected terminal step \(step)")
            return nil
        }
    }

    /// Runs the planner to completion, as the provider's sync loop does.
    mutating func converge(to desired: CloudLayoutSyncTree, limit: Int = 40) throws -> CloudLayoutSyncStep {
        var scratch = Set<String>()
        for _ in 0..<limit {
            let step = CloudLayoutSyncPlanner(snapshot: snapshot, workspaceID: "ws", desired: desired, scratchTabIDs: scratch).step
            switch step {
            case .done, .notReady, .unsupported: return step
            default: if let tab = try perform(step) { scratch.insert(tab) }
            }
        }
        Issue.record("The planner did not converge")
        return .notReady("limit")
    }

    /// The native-tree view of the current daemon layout, for final comparisons.
    var tree: CloudLayoutSyncTree { Self.tree(root) }

    static func tree(_ node: Node) -> CloudLayoutSyncTree {
        switch node {
        case .leaf(_, let tabs, _): return .leaf(tabIDs: tabs, activeTabID: nil)
        case .split(_, let horizontal, let ratio, let first, let second):
            return .split(horizontal: horizontal, ratio: ratio, first: tree(first), second: tree(second))
        }
    }
}

private func leaf(_ tabs: String...) -> CloudLayoutSyncTree { .leaf(tabIDs: tabs, activeTabID: nil) }

@Suite
struct CloudLayoutSyncPlannerTests {
    /// The recorded issue #15770 shape: the machine still has one pane with four tabs,
    /// while the user arranged them locally as three tabs beside one.
    private var flatMachine: FakeDaemonScreen {
        FakeDaemonScreen(root: .leaf(pane: "p1", tabs: ["a", "b", "c", "d"], active: "a"))
    }

    @Test("A matching machine needs no mutation")
    func alreadySynced() {
        let daemon = FakeDaemonScreen(root: .split(
            id: "s1", horizontal: true, ratio: 0.5,
            first: .leaf(pane: "p1", tabs: ["a", "b", "c"], active: "a"),
            second: .leaf(pane: "p2", tabs: ["d"], active: "d")
        ))
        let step = CloudLayoutSyncPlanner(
            snapshot: daemon.snapshot, workspaceID: "ws",
            desired: .split(horizontal: true, ratio: 0.502, first: leaf("a", "b", "c"), second: leaf("d"))
        ).step
        #expect(step == .done)
    }

    @Test("A local drag-split of a multi-tab pane is written to the machine")
    func localSplitConverges() throws {
        var daemon = flatMachine
        let desired = CloudLayoutSyncTree.split(horizontal: true, ratio: 0.62, first: leaf("a", "b", "c"), second: leaf("d"))
        #expect(try daemon.converge(to: desired) == .done)
        #expect(daemon.tree == desired)
        // The placeholder shell that held the new pane open was closed, and only it.
        #expect(daemon.closedTerminals == ["term_scratch1"])
        #expect(daemon.leaves.first?.pane == "p1", "the original pane keeps its identity")
    }

    @Test("A tab moved between existing panes is written with tab.move")
    func tabMoveBetweenPanes() throws {
        var daemon = FakeDaemonScreen(root: .split(
            id: "s1", horizontal: true, ratio: 0.5,
            first: .leaf(pane: "p1", tabs: ["a", "b", "c"], active: "a"),
            second: .leaf(pane: "p2", tabs: ["d"], active: "d")
        ))
        let desired = CloudLayoutSyncTree.split(horizontal: true, ratio: 0.5, first: leaf("a", "c"), second: leaf("d", "b"))
        #expect(try daemon.converge(to: desired) == .done)
        #expect(daemon.tree == desired)
        #expect(daemon.closedTerminals.isEmpty)
        #expect(daemon.mutations <= 2, "existing panes are reused with plain tab moves")
        #expect(daemon.leaves.map(\.pane) == ["p1", "p2"])
    }

    @Test("Reorders, divider drags and direction changes converge", arguments: [
        CloudLayoutSyncTree.split(horizontal: true, ratio: 0.3, first: leaf("c", "a", "b"), second: leaf("d")),
        CloudLayoutSyncTree.split(horizontal: false, ratio: 0.5, first: leaf("a", "b", "c"), second: leaf("d")),
        CloudLayoutSyncTree.split(horizontal: true, ratio: 0.5, first: leaf("d"), second: leaf("a", "b", "c")),
    ])
    func sameMembershipEdits(desired: CloudLayoutSyncTree) throws {
        var daemon = FakeDaemonScreen(root: .split(
            id: "s1", horizontal: true, ratio: 0.5,
            first: .leaf(pane: "p1", tabs: ["a", "b", "c"], active: "a"),
            second: .leaf(pane: "p2", tabs: ["d"], active: "d")
        ))
        #expect(try daemon.converge(to: desired) == .done)
        #expect(daemon.tree == desired)
        #expect(daemon.closedTerminals.isEmpty, "no scratch terminal for a same-membership edit")
    }

    @Test("Dragging a pane's last tab away removes that machine pane")
    func collapseByMovingLastTab() throws {
        var daemon = FakeDaemonScreen(root: .split(
            id: "s1", horizontal: true, ratio: 0.5,
            first: .leaf(pane: "p1", tabs: ["a", "b"], active: "a"),
            second: .leaf(pane: "p2", tabs: ["c"], active: "c")
        ))
        #expect(try daemon.converge(to: leaf("a", "b", "c")) == .done)
        #expect(daemon.tree == leaf("a", "b", "c"))
        #expect(daemon.leaves.map(\.pane) == ["p1"])
    }

    @Test("Nested asymmetric arrangements converge from a flat machine")
    func nestedFromFlat() throws {
        var daemon = FakeDaemonScreen(root: .leaf(pane: "p1", tabs: ["a", "b", "c", "d", "e"], active: "a"))
        let desired = CloudLayoutSyncTree.split(
            horizontal: true, ratio: 0.4,
            first: leaf("a", "b"),
            second: .split(horizontal: false, ratio: 0.7, first: leaf("c"), second: .split(
                horizontal: true, ratio: 0.5, first: leaf("e"), second: leaf("d")
            ))
        )
        #expect(try daemon.converge(to: desired) == .done)
        #expect(daemon.tree == desired)
        #expect(daemon.closedTerminals.count == 3)
    }

    @Test("A tab present on only one side defers the sync")
    func membershipMismatchDefers() {
        let daemon = flatMachine
        let pendingLocal = CloudLayoutSyncPlanner(
            snapshot: daemon.snapshot, workspaceID: "ws",
            desired: .split(horizontal: true, ratio: 0.5, first: leaf("a", "b", "c"), second: leaf("d", "new"))
        ).step
        let unprojected = CloudLayoutSyncPlanner(
            snapshot: daemon.snapshot, workspaceID: "ws",
            desired: .split(horizontal: true, ratio: 0.5, first: leaf("a", "b"), second: leaf("d"))
        ).step
        guard case .notReady = pendingLocal, case .notReady = unprojected else {
            Issue.record("Expected deferral, got \(pendingLocal) and \(unprojected)")
            return
        }
    }

    @Test("Multi-screen and stacked workspaces are left untouched")
    func unsupportedShapes() {
        var snapshot = flatMachine.snapshot
        var screens = snapshot["screens"] as! [[String: Any]]
        screens.append(["id": "scr2", "workspace_id": "ws", "layout": screens[0]["layout"]!])
        snapshot["screens"] = screens
        guard case .unsupported = CloudLayoutSyncPlanner(snapshot: snapshot, workspaceID: "ws", desired: leaf("a", "b", "c", "d")).step else {
            Issue.record("Expected unsupported for several screens")
            return
        }
        var stacked = flatMachine.snapshot
        stacked["screens"] = [["id": "scr", "workspace_id": "ws", "layout": [
            "version": 1, "screen_id": "scr", "root": ["kind": "stack", "pane_ids": ["p1"]],
        ]]]
        guard case .unsupported = CloudLayoutSyncPlanner(snapshot: stacked, workspaceID: "ws", desired: leaf("a", "b", "c", "d")).step else {
            Issue.record("Expected unsupported for a stack")
            return
        }
    }

    @Test("The selected native tab is written as the pane's active tab")
    func activeTabIsWritten() throws {
        var daemon = flatMachine
        #expect(try daemon.converge(to: .leaf(tabIDs: ["a", "b", "c", "d"], activeTabID: "c")) == .done)
        guard case .leaf(_, _, let active) = daemon.root else {
            Issue.record("Expected one pane")
            return
        }
        #expect(active == "c")
    }
}
