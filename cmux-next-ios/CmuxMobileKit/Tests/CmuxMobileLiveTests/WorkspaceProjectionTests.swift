import Foundation
import Testing
@testable import CmuxMobileLive

@Suite struct WorkspaceProjectionTests {
    private static let snapshot = Data(#"{"ok":true,"data":{"workspace_revision":1,"registry_id":"r","workspaces":[{"id":1,"key":"w1","name":"one","resource_id":"ws_1","screens":[{"id":2,"panes":[{"id":3,"tabs":[{"surface":4,"kind":"pty","title":"old"},{"surface":5,"kind":"pty","title":"hidden"}],"tab_groups":[{"id":"g1"}]}]}]}]}}"#.utf8)

    private static func entity(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private static func delta(_ kind: DaemonTreeDelta.Kind, workspace: Int = 1, screen: Int? = 2, pane: Int? = 3,
                              surface: Int? = nil, index: Int? = nil, entity: [String: Any]? = nil,
                              revision: Int? = nil) -> DaemonEvent {
        .delta(DaemonTreeDelta(kind: kind, workspace: workspace, screen: screen, pane: pane, surface: surface,
                               index: index, entity: entity.map(Self.entity), workspaceRevision: revision, registryID: "r"))
    }

    @Test func applyingDeltaWithoutBaselineRequestsSnapshot() async throws {
        let projection = WorkspaceProjection()
        let add = Self.delta(.workspaceAdded, entity: ["id": 1, "key": "w1", "name": "one", "screens": []])
        await #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
            try await projection.apply(add, agents: AgentStates(), activity: [:])
        }
        await #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
            try await projection.apply(.titleChanged(surface: 4, title: "new"), agents: AgentStates(), activity: [:])
        }
    }

    @Test func duplicateTabAddIsIdempotentAndPreservesOrder() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.snapshot, macID: "m")
        let tab: [String: Any] = ["surface": 6, "kind": "pty", "title": "new"]
        let add = Self.delta(.tabAdded, surface: 6, index: 1, entity: tab)
        let first = try await projection.apply(add, agents: AgentStates(), activity: [:])
        let second = try await projection.apply(add, agents: AgentStates(), activity: [:])
        #expect(first?.tree.workspaces[0].tabs.map(\.id) == ["s4", "s6", "s5"])
        #expect(second == nil)
    }

    @Test func duplicateCloseAndUnknownRenameRequestSnapshot() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.snapshot, macID: "m")
        let close = Self.delta(.tabClosed, surface: 5)
        let first = try await projection.apply(close, agents: AgentStates(), activity: [:])
        #expect(first?.tree.surfaces["s5"] == nil)
        #expect(try await projection.apply(close, agents: AgentStates(), activity: [:]) == nil)
        let rename = Self.delta(.tabRenamed, surface: 99, entity: ["surface": 99, "kind": "pty", "title": "bad"])
        await #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
            try await projection.apply(rename, agents: AgentStates(), activity: [:])
        }
    }

    @Test func nestedRenameIsMetadataOnly() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.snapshot, macID: "m")
        let rename = Self.delta(.tabRenamed, surface: 4,
                                entity: ["surface": 4, "kind": "pty", "title": "renamed"])
        let update = try await projection.apply(rename, agents: AgentStates(), activity: [:])
        #expect(update?.topology == false)
        #expect(update?.tree.workspaces.first?.tabs.first?.title == "renamed")
    }

    @Test func tabChangedMovePreservesSelectedSurfaceAndPlaceIndices() async throws {
        let snapshot = Data(#"{"ok":true,"data":{"workspace_revision":1,"registry_id":"r","workspaces":[{"id":1,"key":"w1","name":"one","screens":[{"id":2,"active":true,"active_pane":3,"panes":[{"id":3,"active_tab":1,"tabs":[{"surface":4,"kind":"pty","title":"first"},{"surface":5,"kind":"pty","title":"selected"},{"surface":6,"kind":"pty","title":"last"}]}]}]}]}}"#.utf8)
        let projection = WorkspaceProjection()
        let before = try await projection.reset(snapshot: snapshot, macID: "m")
        #expect(before.workspaces.first?.activeTabID == "s5")
        let moved = Self.delta(.tabChanged, surface: 4, index: 2,
                               entity: ["surface": 4, "kind": "pty", "title": "first"])
        let update = try await projection.apply(moved, agents: AgentStates(), activity: [:])
        let tree = try #require(update?.tree)
        #expect(tree.workspaces.first?.tabs.map(\.id) == ["s5", "s6", "s4"])
        #expect(tree.tabPlaces["s5"]?.index == 0)
        #expect(tree.tabPlaces["s6"]?.index == 1)
        #expect(tree.tabPlaces["s4"]?.index == 2)
        #expect(tree.workspaces.first?.activeTabID == "s5")
        #expect(tree.workspaces.first?.tabs.first?.linkIDs?.isPaneSelected == true)
    }

    private static func selectedTabsSnapshot(surfaces: [Int] = [4, 5, 6], activeIndex: Int = 1) throws -> Data {
        let tabs: [[String: Any]] = surfaces.map { ["surface": $0, "kind": "pty", "title": "Tab \($0)"] }
        let pane: [String: Any] = ["id": 3, "active_tab": activeIndex, "tabs": tabs]
        let screen: [String: Any] = ["id": 2, "active": true, "active_pane": 3, "panes": [pane]]
        let workspace: [String: Any] = ["id": 1, "key": "w1", "name": "one", "screens": [screen]]
        return try JSONSerialization.data(withJSONObject: ["ok": true, "data": [
            "workspace_revision": 1, "registry_id": "r", "workspaces": [workspace],
        ]])
    }

    private static func expectTabs(_ tree: DaemonTree, ordered surfaces: [Int], selected: Int?) {
        let expectedIDs = surfaces.map { "s\($0)" }
        #expect(tree.workspaces.first?.tabs.map(\.id) == expectedIDs)
        #expect(tree.workspaces.first?.activeTabID == selected.map { "s\($0)" })
        let selectedIDs = selected.map { ["s\($0)"] } ?? []
        #expect(tree.workspaces.first?.tabs.filter { $0.linkIDs?.isPaneSelected == true }.map(\.id) == selectedIDs)
        for (index, id) in expectedIDs.enumerated() {
            #expect(tree.tabPlaces[id]?.pane == 3)
            #expect(tree.tabPlaces[id]?.index == index)
        }
    }

    @Test func insertingBeforeSelectedTabPreservesSelectionAndReplayIsNoOp() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.selectedTabsSnapshot(), macID: "m")
        let add = Self.delta(.tabAdded, surface: 7, index: 1,
                             entity: ["surface": 7, "kind": "pty", "title": "inserted"])
        let update = try await projection.apply(add, agents: AgentStates(), activity: [:])
        Self.expectTabs(try #require(update?.tree), ordered: [4, 7, 5, 6], selected: 5)
        let replay = try await projection.apply(add, agents: AgentStates(), activity: [:])
        #expect(replay == nil)
        // A subsequent row publication inspects the stored state after replay.
        let after = try await projection.apply(.titleChanged(surface: 5, title: "still selected"), agents: AgentStates(), activity: [:])
        Self.expectTabs(try #require(after?.tree), ordered: [4, 7, 5, 6], selected: 5)
    }

    @Test func closingTabBeforeSelectionPreservesSelectedSurfaceAndReplayIsNoOp() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.selectedTabsSnapshot(), macID: "m")
        let close = Self.delta(.tabClosed, surface: 4)
        let update = try await projection.apply(close, agents: AgentStates(), activity: [:])
        let tree = try #require(update?.tree)
        Self.expectTabs(tree, ordered: [5, 6], selected: 5)
        #expect(tree.tabPlaces["s4"] == nil)
        let replay = try await projection.apply(close, agents: AgentStates(), activity: [:])
        #expect(replay == nil)
        let after = try await projection.apply(.titleChanged(surface: 5, title: "still selected"), agents: AgentStates(), activity: [:])
        Self.expectTabs(try #require(after?.tree), ordered: [5, 6], selected: 5)
    }

    @Test func closingSelectedMiddleTabSelectsPreviousTab() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.selectedTabsSnapshot(), macID: "m")
        let update = try await projection.apply(Self.delta(.tabClosed, surface: 5), agents: AgentStates(), activity: [:])
        Self.expectTabs(try #require(update?.tree), ordered: [4, 6], selected: 4)
    }

    @Test func closingFirstSelectedTabSelectsNextTab() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.selectedTabsSnapshot(activeIndex: 0), macID: "m")
        let update = try await projection.apply(Self.delta(.tabClosed, surface: 4), agents: AgentStates(), activity: [:])
        Self.expectTabs(try #require(update?.tree), ordered: [5, 6], selected: 5)
    }

    @Test func closingLastTabClearsSelectionAndPlace() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.selectedTabsSnapshot(surfaces: [4], activeIndex: 0), macID: "m")
        let update = try await projection.apply(Self.delta(.tabClosed, surface: 4), agents: AgentStates(), activity: [:])
        let tree = try #require(update?.tree)
        Self.expectTabs(tree, ordered: [], selected: nil)
        #expect(tree.tabPlaces.isEmpty)
        #expect(tree.surfaces.isEmpty)
        #expect(try await projection.apply(Self.delta(.tabClosed, surface: 4), agents: AgentStates(), activity: [:]) == nil)
    }

    @Test func workspaceInsertReindexesDisplacedSurfaces() async throws {
        let snapshot = Data(#"{"ok":true,"data":{"workspace_revision":1,"workspaces":[{"id":1,"key":"one","screens":[{"id":1,"panes":[{"id":1,"tabs":[{"surface":4,"kind":"pty","title":"one"}]}]}]},{"id":2,"key":"two","screens":[{"id":2,"panes":[{"id":2,"tabs":[{"surface":5,"kind":"pty","title":"two"}]}]}]}]}}"#.utf8)
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: snapshot, macID: "m")
        let added: [String: Any] = ["id": 3, "key": "three", "screens": [["id": 3, "panes": [["id": 3, "tabs": [["surface": 6, "kind": "pty", "title": "three"]]]]]]]
        _ = try await projection.apply(Self.delta(.workspaceAdded, workspace: 3, screen: nil, pane: nil, index: 0, entity: added), agents: AgentStates(), activity: [:])
        let update = try await projection.apply(.titleChanged(surface: 5, title: "updated"), agents: AgentStates(), activity: [:])
        #expect(update?.tree.workspaces.map(\.id) == ["three", "one", "two"])
        #expect(update?.tree.workspaces.first(where: { $0.id == "two" })?.tabs.first?.title == "updated")
    }

    @Test func revisionGapDoesNotPartiallyApplyAndHiddenMetadataIsRemoved() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.snapshot, macID: "m")
        let gap = Self.delta(.workspaceChanged, entity: ["id": 1, "key": "w1", "name": "gap", "screens": []], revision: 3)
        await #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
            try await projection.apply(gap, agents: AgentStates(), activity: [:])
        }
        let close = Self.delta(.workspaceClosed, revision: 2)
        let update = try await projection.apply(close, agents: AgentStates(), activity: [:])
        #expect(update?.tree.workspaces.isEmpty == true)
        #expect(update?.tree.surfaces["s5"] == nil)
    }

    @Test func titleUpdateKeepsWorkspaceOrder() async throws {
        let snapshot = Data(#"{"ok":true,"data":{"workspace_revision":1,"workspaces":[{"id":1,"key":"a","name":"a","screens":[]},{"id":2,"key":"b","name":"b","screens":[]}]}}"#.utf8)
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: snapshot, macID: "m")
        let title = Self.delta(.workspaceRenamed, workspace: 2, screen: nil, pane: nil,
                               entity: ["id": 2, "key": "b", "name": "renamed", "screens": []], revision: 2)
        let update = try await projection.apply(title, agents: AgentStates(), activity: [:])
        #expect(update?.tree.workspaces.map(\.id) == ["a", "b"])
    }
}

/// The Mac's side of the cost and equivalence cells: its rows in order, each
/// one workspace with one pane and one agent tab, and the revisioned deltas
/// and snapshots it sends.
private struct ProjectionTruth {
    struct Row {
        var id: Int
        var name: String
        var pinned = false
        var resource: String
        var tabTitle: String

        var tab: [String: Any] {
            ["surface": id, "kind": "pty", "title": tabTitle, "cwd": "/w/\(id)",
             "conversation": ["agent_session": ["session": "sess\(id)"]]]
        }

        var json: [String: Any] {
            var row: [String: Any] = ["id": id, "key": "w\(id)", "name": name, "resource_id": resource, "screens": [[
                "id": id, "active": true, "active_pane": id,
                "panes": [["id": id, "active_tab": 0, "tabs": [tab]]],
            ]]]
            if pinned { row["pinned"] = true }
            return row
        }
    }

    var revision = 1
    var rows: [Row]
    var nextID: Int

    init(workspaces: Int) {
        rows = (1...workspaces).map { Row(id: $0, name: "ws \($0)", resource: "ws_\($0)", tabTitle: "t\($0)") }
        nextID = workspaces + 1
    }

    func snapshot() throws -> Data {
        let data: [String: Any] = ["workspace_revision": revision, "registry_id": "r", "workspaces": rows.map(\.json)]
        return try JSONSerialization.data(withJSONObject: ["ok": true, "data": data])
    }

    private mutating func workspaceDelta(_ kind: DaemonTreeDelta.Kind, _ row: Row, index: Int? = nil) throws -> DaemonEvent {
        revision += 1
        let entity = kind == .workspaceClosed ? nil : try JSONSerialization.data(withJSONObject: row.json)
        return .delta(DaemonTreeDelta(kind: kind, workspace: row.id, index: index, entity: entity,
                                      workspaceRevision: revision, registryID: "r"))
    }

    mutating func rename(_ index: Int, to name: String) throws -> DaemonEvent {
        rows[index].name = name
        return try workspaceDelta(.workspaceRenamed, rows[index])
    }

    mutating func togglePin(_ index: Int) throws -> DaemonEvent {
        rows[index].pinned.toggle()
        return try workspaceDelta(.workspaceChanged, rows[index])
    }

    mutating func changeResource(_ index: Int, to resource: String) throws -> DaemonEvent {
        rows[index].resource = resource
        return try workspaceDelta(.workspaceChanged, rows[index])
    }

    mutating func add(at index: Int) throws -> DaemonEvent {
        let row = Row(id: nextID, name: "ws \(nextID)", resource: "ws_\(nextID)", tabTitle: "t\(nextID)")
        nextID += 1
        rows.insert(row, at: index)
        return try workspaceDelta(.workspaceAdded, row, index: index)
    }

    mutating func close(_ index: Int) throws -> DaemonEvent {
        try workspaceDelta(.workspaceClosed, rows.remove(at: index))
    }

    mutating func move(_ index: Int, to target: Int) throws -> DaemonEvent {
        let row = rows.remove(at: index)
        rows.insert(row, at: min(max(target, 0), rows.count))
        return try workspaceDelta(.workspaceMoved, row, index: target)
    }

    /// A tab rename (`tab-renamed`): nested, no workspace revision.
    mutating func renameTab(_ index: Int, to title: String) throws -> DaemonEvent {
        rows[index].tabTitle = title
        let row = rows[index]
        return .delta(DaemonTreeDelta(kind: .tabRenamed, workspace: row.id, screen: row.id, pane: row.id, surface: row.id,
                                      entity: try JSONSerialization.data(withJSONObject: row.tab), registryID: "r"))
    }

    /// A terminal title (`title-changed`), which names the surface only.
    mutating func retitle(_ index: Int, to title: String) -> DaemonEvent {
        rows[index].tabTitle = title
        return .titleChanged(surface: rows[index].id, title: title)
    }
}

/// Leo: interaction cost stays constant as workspaces grow, never linear
/// degradation. The tick harness (cmux#41082) measured a one-row delta at
/// 1.1 ms with 200 workspaces and 6.8 ms with 1,000. These cells count the
/// projection's whole-list work instead of timing it, and check that the
/// incremental tree stays the tree a fresh snapshot gives.
@Suite struct WorkspaceProjectionCostTests {
    private struct Cost {
        var deltas = 0
        var applied = 0
        var scanned = 0
        var wall: Duration = .zero
    }

    /// `ops` one-row changes over `workspaces` rows, in turn: a workspace
    /// rename, a tab rename, a terminal title and an agent's open ask (the
    /// kinds a busy Mac sends most).
    private static func cost(workspaces: Int, ops: Int) async throws -> Cost {
        var truth = ProjectionTruth(workspaces: workspaces)
        let projection = WorkspaceProjection()
        var agents = AgentStates()
        _ = try await projection.reset(snapshot: truth.snapshot(), macID: "m", agents: agents)
        let before = await projection.scannedRows
        var cost = Cost()
        let clock = ContinuousClock()
        let start = clock.now
        for op in 0..<ops {
            // Spread over the list, the same picks at any size.
            let index = (op &* 7_919) % workspaces
            let update: WorkspaceProjection.Update?
            switch op % 4 {
            case 0: update = try await projection.apply(truth.rename(index, to: "ws r\(op)"), agents: agents, activity: [:])
            case 1: update = try await projection.apply(truth.renameTab(index, to: "tab r\(op)"), agents: agents, activity: [:])
            case 2: update = try await projection.apply(truth.retitle(index, to: "title r\(op)"), agents: agents, activity: [:])
            default:
                agents.pending = ["sess\(truth.rows[index].id)": true]
                update = try await projection.updateAgents(agents: agents, activity: [:])
            }
            cost.deltas += 1
            // An ask's change also republishes the row of the ask it replaced.
            if update?.changedWorkspaceIDs.contains("w\(truth.rows[index].id)") == true { cost.applied += 1 }
        }
        cost.wall = clock.now - start
        cost.scanned = await projection.scannedRows - before
        return cost
    }

    @Test func aOneRowDeltaCostsTheSameAtAThousandWorkspacesAsAtTwoHundred() async throws {
        let ops = 400
        let small = try await Self.cost(workspaces: 200, ops: ops)
        let large = try await Self.cost(workspaces: 1_000, ops: ops)
        for (label, cost) in [("200", small), ("1000", large)] {
            let micros = Int(Double(cost.wall.components.attoseconds) / 1e12 + Double(cost.wall.components.seconds) * 1e6)
            let line = "MATRIX cell=projection_delta_cost workspaces=\(label) deltas=\(cost.deltas) scanned_rows=\(cost.scanned) "
                + "scanned_per_delta=\(cost.scanned / max(cost.deltas, 1)) wall_us_per_delta=\(micros / max(cost.deltas, 1))"
            print(line)
            // The simulator route keeps attachments, not stdout.
            Attachment.record(line + "\n", named: "MATRIX-projection_delta_cost-\(label).txt")
        }
        #expect(small.applied == ops && large.applied == ops, "every delta changes its own row")
        // Counted, not timed: within 1.2x of the 200-workspace cost.
        #expect(large.scanned * 5 <= small.scanned * 6,
                "a one-row delta read \(large.scanned / ops) rows of 1,000 workspaces against \(small.scanned / ops) of 200")
    }

    /// Every delta kind, applied as it arrives, leaves the tree a fresh
    /// snapshot of the Mac's rows gives: order, titles, pins and their
    /// places, and every index map.
    @Test func incrementalTreeMatchesASnapshotAfterEveryDelta() async throws {
        var truth = ProjectionTruth(workspaces: 12)
        let projection = WorkspaceProjection()
        var tree = try await projection.reset(snapshot: truth.snapshot(), macID: "m")
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }
        for op in 0..<300 {
            let count = truth.rows.count
            let index = next(count)
            let event: DaemonEvent
            switch next(count > 4 ? 8 : 6) {
            case 0: event = try truth.rename(index, to: "ws r\(op)")
            case 1: event = try truth.togglePin(index)
            case 2: event = try truth.changeResource(index, to: "ws_r\(op)")
            case 3: event = try truth.renameTab(index, to: "tab r\(op)")
            case 4: event = truth.retitle(index, to: "title r\(op)")
            case 5: event = try truth.add(at: next(count + 1))
            case 6: event = try truth.close(index)
            default: event = try truth.move(index, to: next(count))
            }
            if let update = try await projection.apply(event, agents: AgentStates(), activity: [:]) { tree = update.tree }
            let fresh = try await WorkspaceProjection().reset(snapshot: truth.snapshot(), macID: "m",
                                                              previous: tree.workspaces + tree.homeWorkspaces)
            #expect(tree.workspaces == fresh.workspaces, "op \(op): rows differ from the snapshot's")
            #expect(tree.homeWorkspaces == fresh.homeWorkspaces, "op \(op)")
            #expect(tree.agentTabs == fresh.agentTabs, "op \(op)")
            #expect(tree.surfaces == fresh.surfaces, "op \(op)")
            #expect(tree.directories == fresh.directories, "op \(op)")
            #expect(tree.panes == fresh.panes, "op \(op)")
            #expect(tree.tabPlaces == fresh.tabPlaces, "op \(op)")
            #expect(tree.terminals == fresh.terminals, "op \(op)")
            #expect(tree.workspaceNumbers == fresh.workspaceNumbers, "op \(op)")
            #expect(tree.legacyPinned == fresh.legacyPinned, "op \(op)")
            #expect(tree.revision == fresh.revision, "op \(op)")
            if tree.workspaces != fresh.workspaces { break }
        }
    }
}
