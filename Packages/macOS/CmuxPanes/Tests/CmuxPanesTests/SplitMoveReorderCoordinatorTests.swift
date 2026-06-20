import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

/// Verifies the lifted ``SplitMoveReorderCoordinator`` commands drive the host
/// hooks in exactly the order and under exactly the conditions the legacy
/// `Workspace` Panel-Operations move/reorder bodies did, over a synthetic fake
/// host that records each call.
@MainActor
struct SplitMoveReorderCoordinatorTests {
    /// Records every host call so a test can assert the exact effect sequence.
    /// Bonsplit operations return configurable success; the workspace
    /// orchestration hooks just append to ``calls``.
    final class FakeHost: SplitMoveReorderHosting {
        var workspaceId = UUID()
        var surfaceForPanel: [UUID: TabID] = [:]
        var panelForSurface: [TabID: UUID] = [:]
        var paneForPanel: [UUID: PaneID] = [:]
        var ownedPanels: Set<UUID> = []
        var panes: [PaneID] = []
        var focusedPane: PaneID?
        var tabsByPane: [PaneID: [Bonsplit.Tab]] = [:]
        var selectedTabByPane: [PaneID: Bonsplit.Tab] = [:]
        var adjacency: [PaneID: [String: PaneID]] = [:]

        var moveTabReturns = true
        var reorderTabReturns = true
        var mirrorReorderResult: [UUID]?

        var calls: [String] = []

        func surfaceId(forPanelId panelId: UUID) -> TabID? { surfaceForPanel[panelId] }
        func panelId(forSurfaceId surfaceId: TabID) -> UUID? { panelForSurface[surfaceId] }
        func paneId(forPanelId panelId: UUID) -> PaneID? { paneForPanel[panelId] }
        func hasPanel(_ panelId: UUID) -> Bool { ownedPanels.contains(panelId) }

        var allBonsplitPaneIds: [PaneID] { panes }
        var focusedBonsplitPaneId: PaneID? { focusedPane }
        func tabs(inPane paneId: PaneID) -> [Bonsplit.Tab] { tabsByPane[paneId] ?? [] }
        func selectedTab(inPane paneId: PaneID) -> Bonsplit.Tab? { selectedTabByPane[paneId] }
        func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
            adjacency[paneId]?[String(describing: direction)]
        }

        func moveTab(_ tabId: TabID, toPane paneId: PaneID, atIndex index: Int?) -> Bool {
            calls.append("moveTab(\(tabId.uuid.uuidString.prefix(4)),\(index.map(String.init) ?? "nil"))")
            return moveTabReturns
        }
        func reorderTab(_ tabId: TabID, toIndex index: Int) -> Bool {
            calls.append("reorderTab(\(tabId.uuid.uuidString.prefix(4)),\(index))")
            return reorderTabReturns
        }
        func focusPane(_ paneId: PaneID) { calls.append("focusPane") }
        func selectTab(_ tabId: TabID) { calls.append("selectTab(\(tabId.uuid.uuidString.prefix(4)))") }
        func focusPanel(_ panelId: UUID) { calls.append("focusPanel") }
        func applyTabSelection(tabId: TabID, inPane pane: PaneID) { calls.append("applyTabSelection") }
        func scheduleFocusReconcile() { calls.append("scheduleFocusReconcile") }
        func scheduleTerminalGeometryReconcile() { calls.append("scheduleTerminalGeometryReconcile") }
        func mirrorTabReorder(current: [UUID], requested: [UUID]) -> [UUID]? { mirrorReorderResult }
        func setApplyingRemoteTmuxTabReorder(_ applying: Bool) {
            calls.append("applyingReorder(\(applying))")
        }
    }

    private func makeTab(_ id: UUID) -> Bonsplit.Tab { Bonsplit.Tab(id: TabID(uuid: id), title: "t") }

    private func makeCoordinator(_ host: FakeHost) -> SplitMoveReorderCoordinator {
        let coordinator = SplitMoveReorderCoordinator()
        coordinator.attach(host: host)
        return coordinator
    }

    // MARK: moveSurface

    @Test func moveSurfaceFocusedRunsFocusPaneSelectTabFocusPanelThenGeometry() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        let pane = PaneID()
        host.surfaceForPanel = [panel: TabID(uuid: surface)]
        host.panes = [pane]

        #expect(makeCoordinator(host).moveSurface(panelId: panel, toPane: pane, atIndex: 2, focus: true))
        #expect(host.calls == [
            "moveTab(\(surface.uuidString.prefix(4)),2)",
            "focusPane",
            "selectTab(\(surface.uuidString.prefix(4)))",
            "focusPanel",
            "scheduleTerminalGeometryReconcile",
        ])
    }

    @Test func moveSurfaceUnfocusedSchedulesFocusReconcileInsteadOfActivation() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        let pane = PaneID()
        host.surfaceForPanel = [panel: TabID(uuid: surface)]
        host.panes = [pane]

        #expect(makeCoordinator(host).moveSurface(panelId: panel, toPane: pane, focus: false))
        #expect(host.calls == [
            "moveTab(\(surface.uuidString.prefix(4)),nil)",
            "scheduleFocusReconcile",
            "scheduleTerminalGeometryReconcile",
        ])
    }

    @Test func moveSurfaceFailsWhenSurfaceMissingTargetPaneAbsentOrMoveRejected() {
        // No surface mapping.
        let h1 = FakeHost()
        #expect(makeCoordinator(h1).moveSurface(panelId: UUID(), toPane: PaneID()) == false)
        #expect(h1.calls.isEmpty)

        // Target pane not in the pane list.
        let h2 = FakeHost()
        let panel = UUID()
        h2.surfaceForPanel = [panel: TabID(uuid: UUID())]
        h2.panes = [PaneID()]
        #expect(makeCoordinator(h2).moveSurface(panelId: panel, toPane: PaneID()) == false)
        #expect(h2.calls.isEmpty)

        // bonsplit rejects the move.
        let h3 = FakeHost()
        let pane = PaneID()
        h3.surfaceForPanel = [panel: TabID(uuid: UUID())]
        h3.panes = [pane]
        h3.moveTabReturns = false
        #expect(makeCoordinator(h3).moveSurface(panelId: panel, toPane: pane) == false)
        #expect(h3.calls.count == 1)  // moveTab only, no activation/geometry
    }

    // MARK: moveSurfaceToAdjacentPane

    @Test func moveToAdjacentResolvesSourceAndTargetThenDelegatesToMoveSurface() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        let source = PaneID(), target = PaneID()
        host.ownedPanels = [panel]
        host.surfaceForPanel = [panel: TabID(uuid: surface)]
        host.paneForPanel = [panel: source]
        host.panes = [source, target]
        host.adjacency = [source: [String(describing: NavigationDirection.right): target]]

        #expect(makeCoordinator(host).moveSurfaceToAdjacentPane(panelId: panel, direction: .right))
        #expect(host.calls.contains("focusPanel"))
        #expect(host.calls.first == "moveTab(\(surface.uuidString.prefix(4)),nil)")
    }

    @Test func moveToAdjacentFailsWhenPanelUnownedOrNoAdjacentPane() {
        let h1 = FakeHost()
        #expect(makeCoordinator(h1).moveSurfaceToAdjacentPane(panelId: UUID(), direction: .left) == false)

        let h2 = FakeHost()
        let panel = UUID()
        h2.ownedPanels = [panel]
        h2.paneForPanel = [panel: PaneID()]
        // No adjacency entry.
        #expect(makeCoordinator(h2).moveSurfaceToAdjacentPane(panelId: panel, direction: .left) == false)
    }

    // MARK: reorderSurface

    @Test func reorderSurfaceFocusedAppliesTabSelectionThenGeometry() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        let pane = PaneID()
        host.surfaceForPanel = [panel: TabID(uuid: surface)]
        host.paneForPanel = [panel: pane]

        #expect(makeCoordinator(host).reorderSurface(panelId: panel, toIndex: 3, focus: true))
        #expect(host.calls == [
            "reorderTab(\(surface.uuidString.prefix(4)),3)",
            "applyTabSelection",
            "scheduleTerminalGeometryReconcile",
        ])
    }

    @Test func reorderSurfaceUnfocusedOrPaneMissingSchedulesFocusReconcile() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        host.surfaceForPanel = [panel: TabID(uuid: surface)]
        // No paneForPanel mapping, so even focus:true falls to the reconcile branch.
        #expect(makeCoordinator(host).reorderSurface(panelId: panel, toIndex: 0, focus: true))
        #expect(host.calls == [
            "reorderTab(\(surface.uuidString.prefix(4)),0)",
            "scheduleFocusReconcile",
            "scheduleTerminalGeometryReconcile",
        ])
    }

    // MARK: reorderRemoteTmuxMirrorTabs

    @Test func mirrorReorderAppliesDesiredOrderUnderSuppressionAndRestoresSelectionFocus() {
        let host = FakeHost()
        let panelA = UUID(), panelB = UUID()
        let surfaceA = UUID(), surfaceB = UUID()
        let pane = PaneID()
        host.paneForPanel = [panelA: pane, panelB: pane]
        host.surfaceForPanel = [panelA: TabID(uuid: surfaceA), panelB: TabID(uuid: surfaceB)]
        host.panelForSurface = [TabID(uuid: surfaceA): panelA, TabID(uuid: surfaceB): panelB]
        host.tabsByPane = [pane: [makeTab(surfaceA), makeTab(surfaceB)]]
        let savedSelected = makeTab(surfaceA)
        host.selectedTabByPane = [pane: savedSelected]
        host.focusedPane = pane
        // Desired order swaps the two panels.
        host.mirrorReorderResult = [panelB, panelA]

        #expect(makeCoordinator(host).reorderRemoteTmuxMirrorTabs(toPanelOrder: [panelB, panelA]))
        #expect(host.calls == [
            "applyingReorder(true)",
            "reorderTab(\(surfaceB.uuidString.prefix(4)),0)",
            "reorderTab(\(surfaceA.uuidString.prefix(4)),1)",
            "selectTab(\(surfaceA.uuidString.prefix(4)))",
            "focusPane",
            "scheduleTerminalGeometryReconcile",
            "applyingReorder(false)",
        ])
    }

    @Test func mirrorReorderSkipsWhenPanesDivergeOrNoDesiredOrder() {
        // Panels resolve to two different panes -> skip before any effect.
        let h1 = FakeHost()
        let panelA = UUID(), panelB = UUID()
        h1.paneForPanel = [panelA: PaneID(), panelB: PaneID()]
        #expect(h1.calls.isEmpty)
        #expect(makeCoordinator(h1).reorderRemoteTmuxMirrorTabs(toPanelOrder: [panelA, panelB]) == false)
        #expect(h1.calls.isEmpty)

        // Single pane but mirrorTabReorder reports no change -> skip.
        let h2 = FakeHost()
        let pane = PaneID()
        h2.paneForPanel = [panelA: pane]
        h2.surfaceForPanel = [panelA: TabID(uuid: UUID())]
        h2.tabsByPane = [pane: []]
        h2.mirrorReorderResult = nil
        #expect(makeCoordinator(h2).reorderRemoteTmuxMirrorTabs(toPanelOrder: [panelA]) == false)
        #expect(h2.calls.isEmpty)
    }
}
