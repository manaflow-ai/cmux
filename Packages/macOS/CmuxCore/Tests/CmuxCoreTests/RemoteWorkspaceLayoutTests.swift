import Foundation
import Testing
@testable import CmuxCore

struct RemoteWorkspaceLayoutTests {
    @Test
    func decodesEveryLayoutKindForSnapshotsAndDeltas() throws {
        let leaf: [String: Any] = ["kind": "leaf", "pane_id": "left"]
        let stack: [String: Any] = ["kind": "stack", "pane_ids": ["right", "bottom", "right"]]
        let split: [String: Any] = ["kind": "split", "first": leaf, "second": stack]
        let viewport: [String: Any] = ["kind": "viewport", "columns": [["root": split], ["root": leaf]]]
        let fixtures: [([String: Any], [String: Int])] = [
            (leaf, ["left": 0]),
            (stack, ["right": 0, "bottom": 1]),
            (split, ["left": 0, "right": 1, "bottom": 2]),
            (viewport, ["left": 0, "right": 1, "bottom": 2]),
        ]
        for (root, expected) in fixtures {
            let document: [String: Any] = ["root": root]
            #expect(RemoteWorkspacePaneOrder(document: document).positions == expected)
            let data = try JSONSerialization.data(withJSONObject: document)
            #expect(RemoteWorkspacePaneOrder(data: data).positions == expected)
        }
    }

    @Test
    func unreadableAndFutureLayoutsHaveNoInventedCoordinates() {
        #expect(RemoteWorkspacePaneOrder(document: nil).positions.isEmpty)
        #expect(RemoteWorkspacePaneOrder(document: ["root": ["kind": "future"]]).positions.isEmpty)
        #expect(RemoteWorkspacePaneOrder(data: Data("not JSON".utf8)).positions.isEmpty)
        let order = RemoteWorkspacePaneOrder(document: ["root": ["kind": "stack", "pane_ids": [" ", "left", "left"]]])
        #expect(order.positions == ["left": 0])
    }

    @Test
    func ordersScreensPanesAndHiddenTabsFromOneProjection() {
        let placements = [
            RemoteWorkspacePlacement(screenID: "screen", paneID: "right", screenIndex: 1, paneIndex: 1, focused: true),
            RemoteWorkspacePlacement(screenID: "screen", paneID: "left", screenIndex: 1, paneIndex: 0, tabIndex: 2),
            RemoteWorkspacePlacement(screenID: "screen", paneID: "left", screenIndex: 1, paneIndex: 0, tabIndex: 0),
            RemoteWorkspacePlacement(screenID: "screen", paneID: "left", screenIndex: 1, paneIndex: 0, tabIndex: 1, focused: true),
            RemoteWorkspacePlacement(screenID: "earlier", paneID: "left", screenIndex: 0, paneIndex: 0, focused: true),
        ]
        let rows = RemoteWorkspaceLayout(placements: placements).rows
        #expect(rows.map(\.shownIndex) == [4, 3, 0])
        #expect(rows[1].hiddenIndices == [2, 1])
        #expect(rows.flatMap { [$0.shownIndex] + $0.hiddenIndices }.sorted() == Array(placements.indices))
    }

    @Test
    func missingScreenIdentitiesKeepIndexedAndUnknownScreensDistinct() {
        let rows = RemoteWorkspaceLayout(placements: [
            RemoteWorkspacePlacement(screenID: "0", paneID: "pane", screenIndex: 8),
            RemoteWorkspacePlacement(paneID: "pane", screenIndex: 0, tabIndex: 0),
            RemoteWorkspacePlacement(paneID: "pane", screenIndex: 1),
            RemoteWorkspacePlacement(paneID: "pane"),
            RemoteWorkspacePlacement(paneID: "pane", screenIndex: 0, tabIndex: 1),
            RemoteWorkspacePlacement(screenID: "", paneID: "pane", screenIndex: 2),
        ]).rows
        #expect(rows.map(\.shownIndex) == [1, 2, 5, 0, 3])
        #expect(rows.first?.hiddenIndices == [4])
        #expect(rows.dropFirst().allSatisfy { $0.hiddenIndices.isEmpty })
    }

    @Test
    func stableScreenIdentityTakesPrecedenceOverScreenPosition() {
        let rows = RemoteWorkspaceLayout(placements: [
            RemoteWorkspacePlacement(screenID: "screen", paneID: "pane", screenIndex: 0, tabIndex: 0),
            RemoteWorkspacePlacement(screenID: "screen", paneID: "pane", screenIndex: 1, tabIndex: 1, focused: true),
            RemoteWorkspacePlacement(screenID: "other", paneID: "pane", screenIndex: 0),
        ]).rows
        #expect(rows.map(\.shownIndex) == [1, 2])
        #expect(rows.first?.hiddenIndices == [0])
    }

    @Test
    func legacyPanesKeepArrivalOrderAndSelectTheirFirstOrderedTab() {
        let rows = RemoteWorkspaceLayout(placements: [
            RemoteWorkspacePlacement(paneID: "first", tabIndex: 2),
            RemoteWorkspacePlacement(paneID: "second"),
            RemoteWorkspacePlacement(paneID: "first", tabIndex: 0),
            RemoteWorkspacePlacement(paneID: "first"),
        ]).rows
        #expect(rows.map(\.shownIndex) == [2, 1])
        #expect(rows[0].hiddenIndices == [0, 3])
    }

    @Test
    func equalCoordinatesAndMultipleFocusFlagsHaveStableFallbacks() {
        let rows = RemoteWorkspaceLayout(placements: [
            RemoteWorkspacePlacement(paneID: "first", screenIndex: 0, paneIndex: 0, tabIndex: 0, focused: true),
            RemoteWorkspacePlacement(paneID: "second", screenIndex: 0, paneIndex: 0),
            RemoteWorkspacePlacement(paneID: "first", screenIndex: 0, paneIndex: 0, tabIndex: 0, focused: true),
        ]).rows
        #expect(rows.map(\.shownIndex) == [0, 1])
        #expect(rows[0].hiddenIndices == [2])
    }

    @Test
    func paneLessResourcesFollowPanesInStableKindOrder() {
        let rows = RemoteWorkspaceLayout(placements: [
            RemoteWorkspacePlacement(kindOrder: 2),
            RemoteWorkspacePlacement(paneID: "", kindOrder: 1),
            RemoteWorkspacePlacement(kindOrder: 0),
            RemoteWorkspacePlacement(paneID: "pane", focused: true),
            RemoteWorkspacePlacement(kindOrder: 0),
        ]).rows
        #expect(rows.map(\.shownIndex) == [3, 2, 4, 1, 0])
        #expect(rows.allSatisfy { $0.hiddenIndices.isEmpty })
        #expect(RemoteWorkspaceLayout(placements: []).rows.isEmpty)
    }

    @Test
    func refreshedFocusKeepsMixedResourceTabsInOnePane() {
        func layout(focusedIndex: Int) -> RemoteWorkspaceLayout {
            RemoteWorkspaceLayout(placements: (0..<3).map { index in
                RemoteWorkspacePlacement(
                    screenID: "screen", paneID: "pane", tabIndex: index,
                    focused: index == focusedIndex, kindOrder: index
                )
            })
        }
        let before = layout(focusedIndex: 1)
        let after = layout(focusedIndex: 2)
        #expect(before.rows.count == 1)
        #expect(before.rows[0].shownIndex == 1)
        #expect(before.rows[0].hiddenIndices == [0, 2])
        #expect(after.rows.count == 1)
        #expect(after.rows[0].shownIndex == 2)
        #expect(after.rows[0].hiddenIndices == [0, 1])
    }

    @Test
    func thousandWorkspacesRetainEveryPlacement() {
        let workspaces = (0..<1_000).map { workspace in
            (0..<32).reversed().map { index in
                RemoteWorkspacePlacement(
                    screenID: "screen-\(workspace)", paneID: "pane-\(index / 4)",
                    screenIndex: 0, paneIndex: index / 4, tabIndex: index % 4,
                    focused: index % 4 == 2
                )
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let layouts = workspaces.map { RemoteWorkspaceLayout(placements: $0) }
        let duration = start.duration(to: clock.now)
        print("RemoteWorkspaceLayout: 1000 workspaces, 32000 placements, \(duration)")
        for (workspace, layout) in zip(workspaces, layouts) {
            #expect(layout.rows.count == 8)
            #expect(layout.rows.allSatisfy { $0.hiddenIndices.count == 3 })
            #expect(layout.rows.flatMap { [$0.shownIndex] + $0.hiddenIndices }.sorted() == Array(workspace.indices))
        }
    }
}
