import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

@MainActor
@Suite("Move pane to new outer split", .serialized)
struct PaneOuterSplitMovementTests {
    @Test(arguments: PaneOuterSplitMovement.allCases)
    func promotesNestedPaneToRequestedRootEdge(
        movement: PaneOuterSplitMovement
    ) throws {
        let fixture = try makeNestedFixture()
        let mutation = PaneOuterSplitLayoutMutation()
        let initialNestedSplit = try #require(
            nestedSplit(in: fixture.controller.treeSnapshot())
        )
        let initialNestedSplitID = try #require(
            UUID(uuidString: initialNestedSplit.id)
        )
        let expectedNestedDivider = 0.63
        #expect(
            fixture.controller.setDividerPosition(
                CGFloat(expectedNestedDivider),
                forSplit: initialNestedSplitID
            )
        )
        #expect(
            fixture.controller.setFullWidthTabMode(
                true,
                inPane: fixture.sourcePane
            )
        )
        let beforeTabIds = Set(fixture.controller.allTabIds)
        let beforeSourceTabs = fixture.controller
            .tabs(inPane: fixture.sourcePane)
            .map(\.id)
        let beforeSelectedTab = try #require(
            fixture.controller.selectedTab(inPane: fixture.sourcePane)?.id
        )

        #expect(
            mutation.movePane(
                fixture.sourcePane,
                in: fixture.controller,
                movement: movement
            ) { pane, orientation, tab, insertFirst in
                fixture.controller.splitPane(
                    pane,
                    orientation: orientation,
                    withTab: tab,
                    insertFirst: insertFirst
                )
            }
        )

        guard case .split(let root) = fixture.controller.treeSnapshot() else {
            Issue.record("The promoted layout must have a split root")
            return
        }
        let expectedOrientation: String = movement.orientation == .horizontal
            ? "horizontal"
            : "vertical"
        #expect(root.orientation == expectedOrientation)

        let sourceEdge = movement.insertFirst ? root.first : root.second
        guard case .pane(let sourceNode) = sourceEdge else {
            Issue.record("The moved pane must be a direct child of the new root")
            return
        }
        #expect(sourceNode.id == fixture.sourcePane.id.uuidString)
        #expect(sourceNode.tabs.map { $0.id } == beforeSourceTabs.map { $0.uuid.uuidString })
        #expect(sourceNode.selectedTabId == beforeSelectedTab.uuid.uuidString)

        // The old branch retains its nested split and non-default divider even
        // though removing the source collapses only its degenerate container.
        let remainingEdge = movement.insertFirst ? root.second : root.first
        guard case .split(let remainingRoot) = remainingEdge else {
            Issue.record("The remaining panes must retain their split branch")
            return
        }
        guard case .split(let remainingNested) = remainingRoot.second else {
            Issue.record("The remaining nested split must retain its topology")
            return
        }
        #expect(remainingRoot.orientation == "horizontal")
        #expect(
            remainingNested.orientation == "vertical"
        )
        #expect(
            abs(remainingNested.dividerPosition - expectedNestedDivider) < 0.0001
        )
        #expect(fixture.controller.allPaneIds.count == 4)
        #expect(fixture.controller.isFullWidthTabMode(inPane: fixture.sourcePane))
        #expect(Set(fixture.controller.allTabIds) == beforeTabIds)
        #expect(fixture.controller.focusedPaneId == fixture.sourcePane)
        #expect(
            fixture.controller.selectedTab(inPane: fixture.sourcePane)?.id ==
                beforeSelectedTab
        )

        for tabId in beforeSourceTabs {
            #expect(fixture.controller.paneId(containing: tabId) == fixture.sourcePane)
            #expect(fixture.controller.tab(tabId)?.kind != "cmux.outerSplit.placeholder")
        }
    }

    @Test func directRootEdgeIsANoOp() throws {
        let fixture = try makeNestedFixture()
        let mutation = PaneOuterSplitLayoutMutation()
        #expect(
            mutation.movePane(
                fixture.sourcePane,
                in: fixture.controller,
                movement: .right
            ) { pane, orientation, tab, insertFirst in
                fixture.controller.splitPane(
                    pane,
                    orientation: orientation,
                    withTab: tab,
                    insertFirst: insertFirst
                )
            }
        )
        let afterFirstMove = fixture.controller.treeSnapshot()
        #expect(
            !mutation.movePane(
                fixture.sourcePane,
                in: fixture.controller,
                movement: .right
            ) { pane, orientation, tab, insertFirst in
                fixture.controller.splitPane(
                    pane,
                    orientation: orientation,
                    withTab: tab,
                    insertFirst: insertFirst
                )
            }
        )
        #expect(fixture.controller.treeSnapshot() == afterFirstMove)
    }

    @Test func rejectsControllersThatCannotMoveTabsAcrossPanes() throws {
        let fixture = try makeNestedFixture()
        let mutation = PaneOuterSplitLayoutMutation()
        fixture.controller.configuration.allowCrossPaneTabMove = false
        let before = fixture.controller.treeSnapshot()

        #expect(
            !mutation.movePane(
                fixture.sourcePane,
                in: fixture.controller,
                movement: .right
            ) { pane, orientation, tab, insertFirst in
                fixture.controller.splitPane(
                    pane,
                    orientation: orientation,
                    withTab: tab,
                    insertFirst: insertFirst
                )
            }
        )
        #expect(fixture.controller.treeSnapshot() == before)
    }

    private struct Fixture {
        let controller: BonsplitController
        let sourcePane: PaneID
    }

    private func nestedSplit(
        in tree: ExternalTreeNode
    ) -> ExternalSplitNode? {
        guard case .split(let root) = tree,
              case .split(let nested) = root.second else {
            return nil
        }
        return nested
    }

    private func makeNestedFixture() throws -> Fixture {
        let controller = BonsplitController(
            configuration: BonsplitConfiguration(newTabPosition: .end)
        )
        let leftPane = try #require(controller.focusedPaneId)
        _ = try #require(
            controller.createTab(title: "left", inPane: leftPane)
        )
        _ = try #require(
            controller.createTab(title: "left-second", inPane: leftPane)
        )

        let rightPane = try #require(
            controller.splitPane(
                leftPane,
                orientation: .horizontal,
                withTab: Bonsplit.Tab(title: "right-top"),
                insertFirst: false
            )
        )
        _ = try #require(
            controller.splitPane(
                rightPane,
                orientation: .vertical,
                withTab: Bonsplit.Tab(title: "right-middle"),
                insertFirst: false
            )
        )
        let sourcePane = try #require(
            controller.splitPane(
                rightPane,
                orientation: .horizontal,
                withTab: Bonsplit.Tab(title: "right-bottom"),
                insertFirst: false
            )
        )
        _ = try #require(
            controller.createTab(title: "right-bottom-second", inPane: sourcePane)
        )
        let selectedSourceTab = try #require(
            controller.tabs(inPane: sourcePane).last?.id
        )
        controller.selectTab(selectedSourceTab)
        return Fixture(controller: controller, sourcePane: sourcePane)
    }
}
