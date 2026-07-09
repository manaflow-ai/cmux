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
    case pane(panelIds: [UUID], selectedPanelId: UUID?, isFullWidthTabMode: Bool? = nil)
    case split(isVertical: Bool, dividerPosition: Double, first: CoordinatorLayoutFixture, second: CoordinatorLayoutFixture)

    var sessionLayoutPruneCase: SessionLayoutPruneCase<CoordinatorLayoutFixture> {
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
    ) -> CoordinatorLayoutFixture {
        .pane(
            panelIds: panelIds,
            selectedPanelId: selectedPanelId,
            isFullWidthTabMode: isFullWidthTabMode
        )
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

    static func sessionLayoutBuiltPane(
        panelIds: [UUID],
        selectedPanelId: UUID?,
        isFullWidthTabMode: Bool?
    ) -> CoordinatorLayoutFixture {
        .pane(
            panelIds: panelIds,
            selectedPanelId: selectedPanelId,
            isFullWidthTabMode: isFullWidthTabMode
        )
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

    func sessionFullWidthTabMode(forPaneId paneId: UUID) -> Bool {
        false
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

    // MARK: - Surface resume binding resolution

    /// Stand-in resume binding exposing only the two classification reads the
    /// resolution consults, with identity so the tests can assert which binding
    /// the coordinator returned, exactly as the legacy `Workspace` bodies did.
    private struct FakeBinding: SurfaceResumeBindingResolving, Sendable, Equatable {
        let id: Int
        let isProcessDetected: Bool
        let yieldsToProcessDetected: Bool

        func shouldYieldToDetectedSurfaceResumeBinding(_ detected: FakeBinding) -> Bool {
            // Reproduces the legacy rule shape (stored yields to a detected
            // process-detected binding when stored is process-detected or an
            // agent hook); encoded as a flag here so each case is explicit.
            detected.isProcessDetected && yieldsToProcessDetected
        }
    }

    private func coordinator() -> SessionRestoreCoordinator<CoordinatorLayoutFixture> {
        SessionRestoreCoordinator<CoordinatorLayoutFixture>()
    }

    @Test("reconcile: no stored, detected is process-detected → store detected")
    func reconcileStoresDetectedProcessBinding() {
        let detected = FakeBinding(id: 1, isProcessDetected: true, yieldsToProcessDetected: false)
        let action = coordinator().reconcileResumeBinding(stored: FakeBinding?.none, detected: detected)
        #expect(action == .store(detected))
    }

    @Test("reconcile: no stored, detected not process-detected → keep")
    func reconcileKeepsWhenDetectedNotProcess() {
        let detected = FakeBinding(id: 1, isProcessDetected: false, yieldsToProcessDetected: false)
        let action = coordinator().reconcileResumeBinding(stored: FakeBinding?.none, detected: detected)
        #expect(action == .keep)
    }

    @Test("reconcile: stored process-detected, no detected → remove")
    func reconcileRemovesStaleProcessBinding() {
        let stored = FakeBinding(id: 1, isProcessDetected: true, yieldsToProcessDetected: false)
        let action = coordinator().reconcileResumeBinding(stored: stored, detected: FakeBinding?.none)
        #expect(action == .remove)
    }

    @Test("reconcile: stored not process-detected, no detected → keep")
    func reconcileKeepsManualBindingWhenNoDetection() {
        let stored = FakeBinding(id: 1, isProcessDetected: false, yieldsToProcessDetected: false)
        let action = coordinator().reconcileResumeBinding(stored: stored, detected: FakeBinding?.none)
        #expect(action == .keep)
    }

    @Test("reconcile: stored yields to detected → store detected")
    func reconcileStoresWhenStoredYields() {
        let stored = FakeBinding(id: 1, isProcessDetected: false, yieldsToProcessDetected: true)
        let detected = FakeBinding(id: 2, isProcessDetected: true, yieldsToProcessDetected: false)
        let action = coordinator().reconcileResumeBinding(stored: stored, detected: detected)
        #expect(action == .store(detected))
    }

    @Test("reconcile: stored does not yield but is process-detected → remove")
    func reconcileRemovesNonYieldingProcessBinding() {
        let stored = FakeBinding(id: 1, isProcessDetected: true, yieldsToProcessDetected: false)
        let detected = FakeBinding(id: 2, isProcessDetected: false, yieldsToProcessDetected: false)
        let action = coordinator().reconcileResumeBinding(stored: stored, detected: detected)
        #expect(action == .remove)
    }

    @Test("reconcile: stored does not yield and is not process-detected → keep")
    func reconcileKeepsNonYieldingManualBinding() {
        let stored = FakeBinding(id: 1, isProcessDetected: false, yieldsToProcessDetected: false)
        let detected = FakeBinding(id: 2, isProcessDetected: false, yieldsToProcessDetected: false)
        let action = coordinator().reconcileResumeBinding(stored: stored, detected: detected)
        #expect(action == .keep)
    }

    @Test("effective: no detection source returns stored verbatim (even process-detected)")
    func effectiveNoDetectionReturnsStored() {
        let stored = FakeBinding(id: 1, isProcessDetected: true, yieldsToProcessDetected: false)
        let result = coordinator().effectiveResumeBinding(
            stored: stored,
            detected: FakeBinding?.none,
            hasDetectionSource: false
        )
        #expect(result == stored)
    }

    @Test("effective: detection source, no stored → detected")
    func effectiveReturnsDetectedWhenNoStored() {
        let detected = FakeBinding(id: 2, isProcessDetected: true, yieldsToProcessDetected: false)
        let result = coordinator().effectiveResumeBinding(
            stored: FakeBinding?.none,
            detected: detected,
            hasDetectionSource: true
        )
        #expect(result == detected)
    }

    @Test("effective: detection source, stored process-detected, no detected → nil")
    func effectiveDropsStaleProcessBinding() {
        let stored = FakeBinding(id: 1, isProcessDetected: true, yieldsToProcessDetected: false)
        let result = coordinator().effectiveResumeBinding(
            stored: stored,
            detected: FakeBinding?.none,
            hasDetectionSource: true
        )
        #expect(result == nil)
    }

    @Test("effective: detection source, stored not process-detected, no detected → stored")
    func effectiveKeepsManualBindingWhenNoDetected() {
        let stored = FakeBinding(id: 1, isProcessDetected: false, yieldsToProcessDetected: false)
        let result = coordinator().effectiveResumeBinding(
            stored: stored,
            detected: FakeBinding?.none,
            hasDetectionSource: true
        )
        #expect(result == stored)
    }

    @Test("effective: stored yields to detected → detected")
    func effectiveReturnsDetectedWhenStoredYields() {
        let stored = FakeBinding(id: 1, isProcessDetected: false, yieldsToProcessDetected: true)
        let detected = FakeBinding(id: 2, isProcessDetected: true, yieldsToProcessDetected: false)
        let result = coordinator().effectiveResumeBinding(
            stored: stored,
            detected: detected,
            hasDetectionSource: true
        )
        #expect(result == detected)
    }

    @Test("effective: stored does not yield but is process-detected → nil")
    func effectiveDropsNonYieldingProcessBinding() {
        let stored = FakeBinding(id: 1, isProcessDetected: true, yieldsToProcessDetected: false)
        let detected = FakeBinding(id: 2, isProcessDetected: false, yieldsToProcessDetected: false)
        let result = coordinator().effectiveResumeBinding(
            stored: stored,
            detected: detected,
            hasDetectionSource: true
        )
        #expect(result == nil)
    }

    @Test("effective: stored does not yield and is not process-detected → stored")
    func effectiveKeepsNonYieldingManualBinding() {
        let stored = FakeBinding(id: 1, isProcessDetected: false, yieldsToProcessDetected: false)
        let detected = FakeBinding(id: 2, isProcessDetected: false, yieldsToProcessDetected: false)
        let result = coordinator().effectiveResumeBinding(
            stored: stored,
            detected: detected,
            hasDetectionSource: true
        )
        #expect(result == stored)
    }

    // MARK: - Closed-panel restore anchoring

    @Test("anchor: prefers the next tab when one exists")
    func anchorPrefersNextTab() {
        #expect(coordinator().paneAnchorNeighborIndex(forClosedTabIndex: 1, tabCount: 4) == 2)
    }

    @Test("anchor: closing the last tab falls back to the previous tab")
    func anchorFallsBackToPreviousTab() {
        #expect(coordinator().paneAnchorNeighborIndex(forClosedTabIndex: 3, tabCount: 4) == 2)
    }

    @Test("anchor: closing the only tab has no anchor")
    func anchorNoneForSoleTab() {
        #expect(coordinator().paneAnchorNeighborIndex(forClosedTabIndex: 0, tabCount: 1) == nil)
    }

    @Test("anchor: closing the first tab of many prefers the next tab")
    func anchorFirstOfManyPrefersNext() {
        #expect(coordinator().paneAnchorNeighborIndex(forClosedTabIndex: 0, tabCount: 3) == 1)
    }

    @Test("anchor: closing the last of two falls back to the first")
    func anchorLastOfTwoFallsBack() {
        #expect(coordinator().paneAnchorNeighborIndex(forClosedTabIndex: 1, tabCount: 2) == 0)
    }

    // MARK: - Persisted panel ordering

    @Test("panel order: sidebar order wins, remaining appended in given order")
    func panelOrderMergesSources() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let result = coordinator().persistedPanelIdOrder(
            sidebarOrdered: [a, b],
            remaining: [c, d],
            limit: 100
        )
        #expect(result == [a, b, c, d])
    }

    @Test("panel order: ids already in the sidebar order are dropped from remaining")
    func panelOrderDeduplicatesAcrossSources() {
        let a = UUID(), b = UUID(), c = UUID()
        // `b` appears in both sources; the sidebar (first source) wins its slot
        // and the remaining copy is dropped.
        let result = coordinator().persistedPanelIdOrder(
            sidebarOrdered: [a, b],
            remaining: [b, c],
            limit: 100
        )
        #expect(result == [a, b, c])
    }

    @Test("panel order: duplicates within a single source collapse to the first")
    func panelOrderDeduplicatesWithinSource() {
        let a = UUID(), b = UUID()
        let result = coordinator().persistedPanelIdOrder(
            sidebarOrdered: [a, a, b],
            remaining: [b, b, a],
            limit: 100
        )
        #expect(result == [a, b])
    }

    @Test("panel order: result is truncated to the limit after de-duplication")
    func panelOrderTruncatesToLimit() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let result = coordinator().persistedPanelIdOrder(
            sidebarOrdered: [a, b],
            remaining: [c, d],
            limit: 3
        )
        #expect(result == [a, b, c])
    }

    @Test("panel order: a zero limit yields no panels")
    func panelOrderZeroLimit() {
        let a = UUID()
        let result = coordinator().persistedPanelIdOrder(
            sidebarOrdered: [a],
            remaining: [],
            limit: 0
        )
        #expect(result.isEmpty)
    }
}
