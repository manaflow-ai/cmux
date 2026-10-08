import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing
@testable import CmuxNextBridge

@MainActor
enum BridgeFixture {
    struct Envelope: Decodable { var data: DaemonTree }

    static func store() throws -> DaemonStore {
        let url = try #require(Bundle.module.url(forResource: "list-workspaces", withExtension: "json", subdirectory: "Fixtures"))
        let tree = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)).data
        let store = DaemonStore()
        store.apply(snapshot: tree)
        return store
    }
}

@MainActor
struct LayoutMappingTests {
    @Test func columnsScreenMapsEveryColumnAndHandle() throws {
        let store = try BridgeFixture.store()
        let workspace = try #require(store.workspaces.first)
        let result = LayoutMapping.shared.map(workspace)
        #expect(result.screens.count == 2)
        let columns = result.screens[0].layout.columns
        #expect(columns.count == 2)
        #expect(columns[0].id == LayoutColumnID("column:9"))
        #expect(columns[1].width == 0.5)
        #expect(result.handles.columns[columns[0].id] == DaemonColumnID(rawValue: 9))
        // Split 12 stacks panes 4 over 11.
        guard case let .split(splitID, axis, _, a, b) = columns[0].root else {
            Issue.record("expected a split")
            return
        }
        #expect(axis == .vertical)
        #expect(result.handles.splits[splitID] == DaemonSplitID(rawValue: 12))
        #expect(result.handles.panes[a.panes[0]] == DaemonPaneID(rawValue: 4))
        #expect(result.handles.panes[b.panes[0]] == DaemonPaneID(rawValue: 11))
        #expect(result.handles.paneIDs[DaemonPaneID(rawValue: 7)] == columns[1].root.panes.first)
    }

    @Test func workspaceWithoutScreensMapsToNoScreens() throws {
        let store = try BridgeFixture.store()
        let gamma = try #require(store.workspaces.last)
        #expect(LayoutMapping.shared.map(gamma).screens.isEmpty)
    }

    @Test func stackBecomesExpandedLeafAndUnknownCollapses() {
        var handles = LayoutHandleMap()
        let ids: [DaemonPaneID: LayoutPaneID] = [1: "p1", 2: "p2"]
        let stack = LayoutMapping.shared.node(.stack(panes: [1, 2], expanded: 2), paneIDs: ids, handles: &handles)
        #expect(stack == .leaf("p2"))
        let split = LayoutMapping.shared.node(.split(id: 5, direction: .right, ratio: 0.5, a: .unknown, b: .leaf(1)),
                                       paneIDs: ids, handles: &handles)
        #expect(split == .leaf("p1"))
        #expect(handles.splits.isEmpty)
    }

    @Test func ratiosAreClampedToTheDaemonRange() {
        var handles = LayoutHandleMap()
        let ids: [DaemonPaneID: LayoutPaneID] = [1: "a", 2: "b"]
        let node = LayoutMapping.shared.node(.split(id: 3, direction: .down, ratio: 0.999, a: .leaf(1), b: .leaf(2)),
                                      paneIDs: ids, handles: &handles)
        #expect(node == .split("split:3", axis: .vertical, ratio: SplitRatio.range.upperBound, a: .leaf("a"), b: .leaf("b")))
    }
}
