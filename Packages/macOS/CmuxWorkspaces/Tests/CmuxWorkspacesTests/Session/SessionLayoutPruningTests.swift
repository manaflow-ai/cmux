import Foundation
import Testing
@testable import CmuxWorkspaces

/// Stand-in layout node mirroring the app's `SessionWorkspaceLayoutSnapshot`
/// shape (pane carries panel ids + selection; split carries divider position,
/// orientation, and two children) so the prune algorithm is exercised exactly
/// as the app will drive it, without importing the app target.
private indirect enum LayoutFixture: SessionLayoutPruning, Equatable {
    case pane(panelIds: [UUID], selectedPanelId: UUID?, isFullWidthTabMode: Bool? = nil)
    case split(orientation: String, dividerPosition: Double, first: LayoutFixture, second: LayoutFixture)

    var sessionLayoutPruneCase: SessionLayoutPruneCase<LayoutFixture> {
        switch self {
        case let .pane(panelIds, selectedPanelId, isFullWidthTabMode):
            return .pane(
                panelIds: panelIds,
                selectedPanelId: selectedPanelId,
                isFullWidthTabMode: isFullWidthTabMode
            )
        case let .split(_, dividerPosition, first, second):
            return .split(dividerPosition: dividerPosition, first: first, second: second)
        }
    }

    static func sessionLayoutPrunedPane(
        panelIds: [UUID],
        selectedPanelId: UUID?,
        isFullWidthTabMode: Bool?
    ) -> LayoutFixture {
        .pane(
            panelIds: panelIds,
            selectedPanelId: selectedPanelId,
            isFullWidthTabMode: isFullWidthTabMode
        )
    }

    func sessionLayoutPrunedSplit(
        dividerPosition: Double,
        first: LayoutFixture,
        second: LayoutFixture
    ) -> LayoutFixture {
        guard case let .split(orientation, _, _, _) = self else {
            return .split(orientation: "horizontal", dividerPosition: dividerPosition, first: first, second: second)
        }
        return .split(orientation: orientation, dividerPosition: dividerPosition, first: first, second: second)
    }
}

@Suite("SessionLayoutPruning")
struct SessionLayoutPruningTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    @Test("pane keeps surviving panels and the selected id")
    func paneKeepsSurvivors() {
        let node = LayoutFixture.pane(panelIds: [a, b, c], selectedPanelId: b)
        #expect(node.sessionLayoutPruned(keeping: [a, b]) == .pane(panelIds: [a, b], selectedPanelId: b))
    }

    @Test("pane reselects first survivor when selection is pruned away")
    func paneReselectsFirst() {
        let node = LayoutFixture.pane(panelIds: [a, b, c], selectedPanelId: c)
        #expect(node.sessionLayoutPruned(keeping: [a, b]) == .pane(panelIds: [a, b], selectedPanelId: a))
    }

    @Test("pane with no survivors prunes to nil")
    func paneEmptyPrunes() {
        let node = LayoutFixture.pane(panelIds: [a, b], selectedPanelId: a)
        #expect(node.sessionLayoutPruned(keeping: [c]) == nil)
    }

    @Test("split preserves orientation and divider when both children survive")
    func splitKeepsBoth() {
        let node = LayoutFixture.split(
            orientation: "vertical",
            dividerPosition: 0.42,
            first: .pane(panelIds: [a], selectedPanelId: a),
            second: .pane(panelIds: [b], selectedPanelId: b)
        )
        #expect(node.sessionLayoutPruned(keeping: [a, b]) == node)
    }

    @Test("split collapses to the surviving child when one side empties")
    func splitCollapses() {
        let node = LayoutFixture.split(
            orientation: "vertical",
            dividerPosition: 0.5,
            first: .pane(panelIds: [a], selectedPanelId: a),
            second: .pane(panelIds: [b], selectedPanelId: b)
        )
        #expect(node.sessionLayoutPruned(keeping: [b]) == .pane(panelIds: [b], selectedPanelId: b))
    }

    @Test("split prunes to nil when both children empty")
    func splitEmptyPrunes() {
        let node = LayoutFixture.split(
            orientation: "horizontal",
            dividerPosition: 0.5,
            first: .pane(panelIds: [a], selectedPanelId: a),
            second: .pane(panelIds: [b], selectedPanelId: b)
        )
        #expect(node.sessionLayoutPruned(keeping: [c]) == nil)
    }
}
