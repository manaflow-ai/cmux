import Foundation
import Testing

@testable import CmuxWorkspaces

/// In-memory fake of the workspace-side tree seam. Models a set of panes, each
/// with an ordered list of surface ids and a selected index, plus a
/// surface->panel mapping and a panel registry.
@MainActor
private final class FakeTree: WorkspaceSurfaceTreeReading {
    struct Pane {
        var id: UUID
        var surfaceIds: [UUID]
        var selectedIndex: Int?
    }

    var panes: [Pane] = []
    var paneSpatialOrder: [UUID] = []
    var focusedPaneId: UUID?
    var surfaceToPanel: [UUID: UUID] = [:]
    var registry: Set<UUID> = []
    var firstSidebarOrderedPanelId: UUID?

    var lastOrderedPanelIds: [UUID] = []
    private(set) var bumpCount = 0
    func bumpPaneLayoutVersion() { bumpCount &+= 1 }

    var surfaceIdsInTabOrderAcrossAllPanes: [UUID] {
        panes.flatMap(\.surfaceIds)
    }

    var focusedPaneSelectedSurfaceId: UUID? {
        guard let focusedPaneId, let pane = panes.first(where: { $0.id == focusedPaneId }),
              let index = pane.selectedIndex, pane.surfaceIds.indices.contains(index) else { return nil }
        return pane.surfaceIds[index]
    }

    var allPaneIds: [UUID] { panes.map(\.id) }
    var spatiallyOrderedPaneIds: [UUID] { paneSpatialOrder }

    func selectedSurfaceId(inPaneId paneId: UUID) -> UUID? {
        guard let pane = panes.first(where: { $0.id == paneId }),
              let index = pane.selectedIndex, pane.surfaceIds.indices.contains(index) else { return nil }
        return pane.surfaceIds[index]
    }

    func surfaceIdsInTabOrder(inPaneId paneId: UUID) -> [UUID] {
        panes.first(where: { $0.id == paneId })?.surfaceIds ?? []
    }

    func panelId(forSurfaceId surfaceId: UUID) -> UUID? { surfaceToPanel[surfaceId] }
    func panelExists(_ panelId: UUID) -> Bool { registry.contains(panelId) }
    var allPanelIds: [UUID] { Array(registry) }
}

@MainActor
@Suite struct WorkspaceSurfaceListModelTests {
    private func make() -> (WorkspaceSurfaceListModel, FakeTree) {
        let tree = FakeTree()
        let model = WorkspaceSurfaceListModel()
        model.attach(tree: tree)
        return (model, tree)
    }

    @Test func orderedPanelIdsFollowsTabOrderThenAppendsOrphansSorted() {
        let (model, tree) = make()
        let s1 = UUID(), s2 = UUID()
        let p1 = UUID(), p2 = UUID()
        // Two orphan panels with deterministic uuidString order.
        let orphanA = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let orphanB = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        tree.panes = [.init(id: UUID(), surfaceIds: [s1, s2], selectedIndex: 0)]
        tree.surfaceToPanel = [s1: p1, s2: p2]
        tree.registry = [p1, p2, orphanA, orphanB]

        #expect(model.orderedPanelIds == [p1, p2, orphanA, orphanB])
    }

    @Test func orderedPanelIdsDropsSurfacesWithoutLivePanels() {
        let (model, tree) = make()
        let s1 = UUID(), s2 = UUID()
        let p1 = UUID(), p2 = UUID()
        tree.panes = [.init(id: UUID(), surfaceIds: [s1, s2], selectedIndex: 0)]
        tree.surfaceToPanel = [s1: p1, s2: p2]
        tree.registry = [p1] // p2 not in registry

        #expect(model.orderedPanelIds == [p1])
    }

    @Test func orderedPanelIdsDeduplicatesRepeatedSurfaces() {
        let (model, tree) = make()
        let s1 = UUID(), s2 = UUID()
        let p1 = UUID()
        tree.panes = [.init(id: UUID(), surfaceIds: [s1, s2], selectedIndex: 0)]
        tree.surfaceToPanel = [s1: p1, s2: p1]
        tree.registry = [p1]

        #expect(model.orderedPanelIds == [p1])
    }

    @Test func focusedPanelIdResolvesThroughFocusedPaneSelection() {
        let (model, tree) = make()
        let pane = UUID(), s1 = UUID(), p1 = UUID()
        tree.panes = [.init(id: pane, surfaceIds: [s1], selectedIndex: 0)]
        tree.focusedPaneId = pane
        tree.surfaceToPanel = [s1: p1]
        tree.registry = [p1]

        #expect(model.focusedPanelId == p1)
    }

    @Test func focusedPanelIdNilWhenNoPaneFocused() {
        let (model, tree) = make()
        let s1 = UUID(), p1 = UUID()
        tree.panes = [.init(id: UUID(), surfaceIds: [s1], selectedIndex: 0)]
        tree.surfaceToPanel = [s1: p1]
        tree.registry = [p1]

        #expect(model.focusedPanelId == nil)
    }

    @Test func representativePrefersFocusedWhenItExists() {
        let (model, tree) = make()
        let pane = UUID(), s1 = UUID(), p1 = UUID()
        tree.panes = [.init(id: pane, surfaceIds: [s1], selectedIndex: 0)]
        tree.focusedPaneId = pane
        tree.surfaceToPanel = [s1: p1]
        tree.registry = [p1]

        #expect(model.representativePanelIdForWorkspaceManualUnread() == p1)
    }

    @Test func representativeFallsBackToSpatiallyFirstSelectedWhenNoFocus() {
        let (model, tree) = make()
        let paneA = UUID(), paneB = UUID()
        let sA = UUID(), sB = UUID()
        let pA = UUID(), pB = UUID()
        tree.panes = [
            .init(id: paneA, surfaceIds: [sA], selectedIndex: 0),
            .init(id: paneB, surfaceIds: [sB], selectedIndex: 0),
        ]
        // Spatial order puts B before A.
        tree.paneSpatialOrder = [paneB, paneA]
        tree.surfaceToPanel = [sA: pA, sB: pB]
        tree.registry = [pA, pB]

        #expect(model.representativePanelIdForWorkspaceManualUnread() == pB)
    }

    @Test func representativeFallsBackToSidebarFirstWhenNoSelection() {
        let (model, tree) = make()
        let sidebarFirst = UUID()
        tree.firstSidebarOrderedPanelId = sidebarFirst

        #expect(model.representativePanelIdForWorkspaceManualUnread() == sidebarFirst)
    }

    @Test func effectiveSelectedPanelIdResolvesPerPane() {
        let (model, tree) = make()
        let pane = UUID(), s1 = UUID(), p1 = UUID()
        tree.panes = [.init(id: pane, surfaceIds: [s1], selectedIndex: 0)]
        tree.surfaceToPanel = [s1: p1]
        tree.registry = [p1]

        #expect(model.effectiveSelectedPanelId(inPaneId: pane) == p1)
        #expect(model.effectiveSelectedPanelId(inPaneId: UUID()) == nil)
    }

    @Test func surfaceIdsLeftRightAndCloseOthers() {
        let (model, tree) = make()
        let pane = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        tree.panes = [.init(id: pane, surfaceIds: [a, b, c], selectedIndex: 0)]

        #expect(model.surfaceIdsToLeft(of: b, inPaneId: pane) == [a])
        #expect(model.surfaceIdsToRight(of: b, inPaneId: pane) == [c])
        #expect(model.surfaceIdsToCloseOthers(of: b, inPaneId: pane) == [a, c])
        // Anchor absent.
        #expect(model.surfaceIdsToLeft(of: UUID(), inPaneId: pane) == [])
        // Last tab has nothing to the right.
        #expect(model.surfaceIdsToRight(of: c, inPaneId: pane) == [])
    }

    @Test func registerGeometryChangeBumpsOnlyOnReorder() {
        let (model, tree) = make()
        let s1 = UUID(), s2 = UUID()
        let p1 = UUID(), p2 = UUID()
        let pane = UUID()
        tree.panes = [.init(id: pane, surfaceIds: [s1, s2], selectedIndex: 0)]
        tree.surfaceToPanel = [s1: p1, s2: p2]
        tree.registry = [p1, p2]

        // First call: order changed from empty -> bump.
        #expect(model.registerGeometryChange() == true)
        #expect(tree.bumpCount == 1)
        #expect(tree.lastOrderedPanelIds == [p1, p2])

        // No change -> no bump.
        #expect(model.registerGeometryChange() == false)
        #expect(tree.bumpCount == 1)

        // Reorder -> bump.
        tree.panes = [.init(id: pane, surfaceIds: [s2, s1], selectedIndex: 0)]
        #expect(model.registerGeometryChange() == true)
        #expect(tree.bumpCount == 2)
        #expect(tree.lastOrderedPanelIds == [p2, p1])
    }

    @Test func detachedModelReturnsEmptyDefaults() {
        let model = WorkspaceSurfaceListModel()
        #expect(model.orderedPanelIds == [])
        #expect(model.focusedPanelId == nil)
        #expect(model.representativePanelIdForWorkspaceManualUnread() == nil)
        #expect(model.registerGeometryChange() == false)
    }
}
