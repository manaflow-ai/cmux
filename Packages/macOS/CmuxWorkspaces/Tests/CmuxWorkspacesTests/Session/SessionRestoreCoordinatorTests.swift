import Foundation
import Testing
import Bonsplit
@testable import CmuxWorkspaces

/// Stand-in layout node mirroring the app's `SessionWorkspaceLayoutSnapshot`
/// shape so the coordinator's snapshot/restore bridge is exercised exactly as
/// the app will drive it, without importing the app target. Conforms to both
/// the read seam (``SessionLayoutPruning``, used by `applySessionDividerPositions`)
/// and the build seam (``SessionLayoutNodeBuilding``, used by `sessionLayoutSnapshot`).
private indirect enum CoordinatorLayoutFixture: SessionLayoutPruning, SessionLayoutNodeBuilding, Equatable {
    case pane(panelIds: [UUID], selectedPanelId: UUID?)
    case split(isVertical: Bool, dividerPosition: Double, first: CoordinatorLayoutFixture, second: CoordinatorLayoutFixture)

    var sessionLayoutPruneCase: SessionLayoutPruneCase<CoordinatorLayoutFixture> {
        switch self {
        case let .pane(panelIds, selectedPanelId):
            return .pane(panelIds: panelIds, selectedPanelId: selectedPanelId)
        case let .split(_, dividerPosition, first, second):
            return .split(dividerPosition: dividerPosition, first: first, second: second)
        }
    }

    static func sessionLayoutPrunedPane(panelIds: [UUID], selectedPanelId: UUID?) -> CoordinatorLayoutFixture {
        .pane(panelIds: panelIds, selectedPanelId: selectedPanelId)
    }

    func sessionLayoutPrunedSplit(
        dividerPosition: Double,
        first: CoordinatorLayoutFixture,
        second: CoordinatorLayoutFixture
    ) -> CoordinatorLayoutFixture {
        guard case let .split(isVertical, _, _, _) = self else {
            return .split(isVertical: false, dividerPosition: dividerPosition, first: first, second: second)
        }
        return .split(isVertical: isVertical, dividerPosition: dividerPosition, first: first, second: second)
    }

    static func sessionLayoutBuiltPane(panelIds: [UUID], selectedPanelId: UUID?) -> CoordinatorLayoutFixture {
        .pane(panelIds: panelIds, selectedPanelId: selectedPanelId)
    }

    static func sessionLayoutBuiltSplit(
        isVertical: Bool,
        dividerPosition: Double,
        first: CoordinatorLayoutFixture,
        second: CoordinatorLayoutFixture
    ) -> CoordinatorLayoutFixture {
        .split(isVertical: isVertical, dividerPosition: dividerPosition, first: first, second: second)
    }
}

@MainActor
private final class FakeRestoreHost: WorkspaceSessionRestoreHosting {
    var surfaceIdToPanelId: [TabID: UUID]
    private(set) var appliedDividers: [(position: CGFloat, splitID: UUID)] = []

    init(surfaceIdToPanelId: [TabID: UUID] = [:]) {
        self.surfaceIdToPanelId = surfaceIdToPanelId
    }

    func applySessionDividerPosition(_ position: CGFloat, forSplit splitID: UUID) {
        appliedDividers.append((position, splitID))
    }
}

@MainActor
@Suite("SessionRestoreCoordinator")
struct SessionRestoreCoordinatorTests {
    private func tab(_ uuid: UUID) -> ExternalTab {
        ExternalTab(id: uuid.uuidString, title: "")
    }

    private func pane(id: String, tabs: [ExternalTab], selected: UUID?) -> ExternalTreeNode {
        .pane(
            ExternalPaneNode(
                id: id,
                frame: PixelRect(x: 0, y: 0, width: 100, height: 100),
                tabs: tabs,
                selectedTabId: selected?.uuidString
            )
        )
    }

    @Test("snapshot maps a leaf pane's tabs to panel ids and the selected panel")
    func snapshotLeafPane() {
        let surfaceA = UUID(), surfaceB = UUID()
        let panelA = UUID(), panelB = UUID()
        let host = FakeRestoreHost(surfaceIdToPanelId: [
            TabID(uuid: surfaceA): panelA,
            TabID(uuid: surfaceB): panelB,
        ])
        let coordinator = SessionRestoreCoordinator<CoordinatorLayoutFixture>()
        coordinator.attach(host: host)

        let tree = pane(id: "p1", tabs: [tab(surfaceA), tab(surfaceB)], selected: surfaceB)
        let snapshot = coordinator.sessionLayoutSnapshot(from: tree)

        #expect(snapshot == .pane(panelIds: [panelA, panelB], selectedPanelId: panelB))
    }

    @Test("snapshot skips tabs with no panel mapping and de-duplicates")
    func snapshotSkipsUnmapped() {
        let surfaceA = UUID(), surfaceUnmapped = UUID()
        let panelA = UUID()
        let host = FakeRestoreHost(surfaceIdToPanelId: [TabID(uuid: surfaceA): panelA])
        let coordinator = SessionRestoreCoordinator<CoordinatorLayoutFixture>()
        coordinator.attach(host: host)

        // surfaceA appears twice (same panel) and an unmapped surface appears once.
        let tree = pane(
            id: "p1",
            tabs: [tab(surfaceA), tab(surfaceUnmapped), tab(surfaceA)],
            selected: surfaceUnmapped
        )
        let snapshot = coordinator.sessionLayoutSnapshot(from: tree)

        // Unmapped selection resolves to nil; the panel id appears once.
        #expect(snapshot == .pane(panelIds: [panelA], selectedPanelId: nil))
    }

    @Test("snapshot preserves split orientation and divider position")
    func snapshotSplit() {
        let surfaceA = UUID(), surfaceB = UUID()
        let panelA = UUID(), panelB = UUID()
        let host = FakeRestoreHost(surfaceIdToPanelId: [
            TabID(uuid: surfaceA): panelA,
            TabID(uuid: surfaceB): panelB,
        ])
        let coordinator = SessionRestoreCoordinator<CoordinatorLayoutFixture>()
        coordinator.attach(host: host)

        let tree = ExternalTreeNode.split(
            ExternalSplitNode(
                id: UUID().uuidString,
                orientation: "Vertical",
                dividerPosition: 0.37,
                first: pane(id: "a", tabs: [tab(surfaceA)], selected: surfaceA),
                second: pane(id: "b", tabs: [tab(surfaceB)], selected: surfaceB)
            )
        )
        let snapshot = coordinator.sessionLayoutSnapshot(from: tree)

        #expect(snapshot == .split(
            isVertical: true,
            dividerPosition: 0.37,
            first: .pane(panelIds: [panelA], selectedPanelId: panelA),
            second: .pane(panelIds: [panelB], selectedPanelId: panelB)
        ))
    }

    @Test("apply divider positions issues one write per matching split")
    func applyDividers() {
        let host = FakeRestoreHost()
        let coordinator = SessionRestoreCoordinator<CoordinatorLayoutFixture>()
        coordinator.attach(host: host)

        let outerSplitID = UUID(), innerSplitID = UUID()
        let liveTree = ExternalTreeNode.split(
            ExternalSplitNode(
                id: outerSplitID.uuidString,
                orientation: "horizontal",
                dividerPosition: 0.5,
                first: pane(id: "a", tabs: [], selected: nil),
                second: .split(
                    ExternalSplitNode(
                        id: innerSplitID.uuidString,
                        orientation: "vertical",
                        dividerPosition: 0.5,
                        first: pane(id: "b", tabs: [], selected: nil),
                        second: pane(id: "c", tabs: [], selected: nil)
                    )
                )
            )
        )
        let snapshot = CoordinatorLayoutFixture.split(
            isVertical: false,
            dividerPosition: 0.25,
            first: .pane(panelIds: [], selectedPanelId: nil),
            second: .split(
                isVertical: true,
                dividerPosition: 0.75,
                first: .pane(panelIds: [], selectedPanelId: nil),
                second: .pane(panelIds: [], selectedPanelId: nil)
            )
        )

        coordinator.applySessionDividerPositions(snapshotNode: snapshot, liveNode: liveTree)

        #expect(host.appliedDividers.count == 2)
        #expect(host.appliedDividers[0].splitID == outerSplitID)
        #expect(host.appliedDividers[0].position == 0.25)
        #expect(host.appliedDividers[1].splitID == innerSplitID)
        #expect(host.appliedDividers[1].position == 0.75)
    }

    @Test("apply divider positions is a no-op when shapes diverge")
    func applyDividersShapeMismatch() {
        let host = FakeRestoreHost()
        let coordinator = SessionRestoreCoordinator<CoordinatorLayoutFixture>()
        coordinator.attach(host: host)

        // Snapshot is a split but the live node is a leaf pane: legacy `default` branch.
        let liveTree = pane(id: "a", tabs: [], selected: nil)
        let snapshot = CoordinatorLayoutFixture.split(
            isVertical: false,
            dividerPosition: 0.5,
            first: .pane(panelIds: [], selectedPanelId: nil),
            second: .pane(panelIds: [], selectedPanelId: nil)
        )

        coordinator.applySessionDividerPositions(snapshotNode: snapshot, liveNode: liveTree)

        #expect(host.appliedDividers.isEmpty)
    }
}
