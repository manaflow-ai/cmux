import Bonsplit
import Foundation
import Testing

@testable import CmuxWorkspaces

/// Minimal tree fake so the coordinator's real `WorkspaceSurfaceListModel`
/// returns deterministic per-pane tab order for the close-slicing tests.
@MainActor
private final class ContextMenuFakeTree: WorkspaceSurfaceTreeReading {
    var surfaceOrderByPane: [UUID: [UUID]] = [:]

    var surfaceIdsInTabOrderAcrossAllPanes: [UUID] { surfaceOrderByPane.values.flatMap { $0 } }
    var focusedPaneSelectedSurfaceId: UUID? { nil }
    var allPaneIds: [UUID] { Array(surfaceOrderByPane.keys) }
    var spatiallyOrderedPaneIds: [UUID] { Array(surfaceOrderByPane.keys) }
    func selectedSurfaceId(inPaneId paneId: UUID) -> UUID? { nil }
    func surfaceIdsInTabOrder(inPaneId paneId: UUID) -> [UUID] { surfaceOrderByPane[paneId] ?? [] }
    func panelId(forSurfaceId surfaceId: UUID) -> UUID? { surfaceId }
    func panelExists(_ panelId: UUID) -> Bool { true }
    var allPanelIds: [UUID] { [] }
    var firstSidebarOrderedPanelId: UUID? { nil }
    var lastOrderedPanelIds: [UUID] = []
    func bumpPaneLayoutVersion() {}
}

/// Recording host that captures every forwarded effect and serves scripted
/// resolution results, so the coordinator's slicing/index/dispatch logic can be
/// verified without the app-target `Workspace`.
@MainActor
private final class RecordingContextMenuHost: WorkspaceContextMenuHosting {
    let workspaceId = UUID()

    // Resolution stubs.
    var surfaceToPanel: [UUID: UUID] = [:]
    var paneByPanel: [UUID: PaneID] = [:]
    var insertionIndex = 7
    var newTerminalResult: UUID?
    var newBrowserResult: UUID?
    var canMoveToNewWorkspace = true
    var moveTargets: [WorkspaceContextMoveTarget] = []
    var moveToNewWorkspaceResult = true
    var moveToExistingResult = true

    // Recorded effects.
    var closedTabIds: [[TabID]] = []
    var renamedTabs: [TabID] = []
    var copiedSurfaceIds: [UUID] = []
    var reorders: [(UUID, Int)] = []
    var newTerminalCalls: [(PaneID, UUID?)] = []
    var newBrowserCalls: [(PaneID, UUID?)] = []
    var movedToNewWorkspacePanels: [UUID] = []
    var movedToExisting: [(UUID, UUID)] = []
    var moveFailureAlerts = 0

    func panelId(forSurfaceId surfaceId: TabID) -> UUID? { surfaceToPanel[surfaceId.uuid] }
    func paneId(forPanelId panelId: UUID) -> PaneID? { paneByPanel[panelId] }

    func closeTabsFromContextMenu(_ tabIds: [TabID], skipPinned: Bool) {
        closedTabIds.append(tabIds)
    }

    func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int { insertionIndex }

    func newTerminalSurface(inPane paneId: PaneID, workingDirectoryFallbackSourcePanelId sourcePanelId: UUID?) -> UUID? {
        newTerminalCalls.append((paneId, sourcePanelId))
        return newTerminalResult
    }

    func newBrowserSurface(inPane paneId: PaneID, inheritingProfileFromPanelId anchorPanelId: UUID?) -> UUID? {
        newBrowserCalls.append((paneId, anchorPanelId))
        return newBrowserResult
    }

    func reorderSurface(panelId: UUID, toIndex index: Int) { reorders.append((panelId, index)) }

    func presentRenamePrompt(tabId: TabID) { renamedTabs.append(tabId) }

    func copySurfaceIdentifiersToPasteboard(surfaceId: UUID) { copiedSurfaceIds.append(surfaceId) }

    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool { canMoveToNewWorkspace }

    func workspaceMoveTargets(forBonsplitTab tabId: TabID) -> [WorkspaceContextMoveTarget] { moveTargets }

    func moveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        movedToNewWorkspacePanels.append(panelId)
        return moveToNewWorkspaceResult
    }

    func moveSurface(panelId: UUID, toWorkspace workspaceId: UUID) -> Bool {
        movedToExisting.append((panelId, workspaceId))
        return moveToExistingResult
    }

    func presentMoveFailureAlert() { moveFailureAlerts += 1 }
}

@MainActor
@Suite struct WorkspaceContextMenuCoordinatorTests {
    private func make() -> (WorkspaceContextMenuCoordinator, RecordingContextMenuHost, ContextMenuFakeTree, WorkspaceSurfaceListModel) {
        let tree = ContextMenuFakeTree()
        let surfaceList = WorkspaceSurfaceListModel()
        surfaceList.attach(tree: tree)
        let coordinator = WorkspaceContextMenuCoordinator(surfaceList: surfaceList)
        let host = RecordingContextMenuHost()
        coordinator.attach(host: host)
        return (coordinator, host, tree, surfaceList)
    }

    @Test func closeToLeftRightOthersSliceTheOrderAndForwardToClose() {
        let (coordinator, host, tree, _) = make()
        let pane = PaneID()
        let a = TabID(), b = TabID(), c = TabID(), d = TabID()
        tree.surfaceOrderByPane[pane.id] = [a.uuid, b.uuid, c.uuid, d.uuid]

        coordinator.closeTabsToLeft(of: c, inPane: pane)
        coordinator.closeTabsToRight(of: c, inPane: pane)
        coordinator.closeOtherTabs(than: c, inPane: pane)

        #expect(host.closedTabIds[0].map(\.uuid) == [a.uuid, b.uuid])
        #expect(host.closedTabIds[1].map(\.uuid) == [d.uuid])
        #expect(host.closedTabIds[2].map(\.uuid) == [a.uuid, b.uuid, d.uuid])
    }

    @Test func renameAndCopyForwardThroughResolution() {
        let (coordinator, host, _, _) = make()
        let tab = TabID()
        let panel = UUID()
        host.surfaceToPanel[tab.uuid] = panel

        coordinator.renameTab(tab)
        coordinator.copyIdentifiers(for: tab)

        #expect(host.renamedTabs == [tab])
        #expect(host.copiedSurfaceIds == [panel])
    }

    @Test func copyIdentifiersNoopWhenSurfaceUnresolved() {
        let (coordinator, host, _, _) = make()
        coordinator.copyIdentifiers(for: TabID())
        #expect(host.copiedSurfaceIds.isEmpty)
    }

    @Test func createTerminalToRightReordersToInsertionIndexWithSourceFallback() {
        let (coordinator, host, _, _) = make()
        let anchor = TabID()
        let anchorPanel = UUID()
        let pane = PaneID()
        let created = UUID()
        host.surfaceToPanel[anchor.uuid] = anchorPanel
        host.insertionIndex = 4
        host.newTerminalResult = created

        coordinator.createTerminalToRight(of: anchor, inPane: pane)

        #expect(host.newTerminalCalls.count == 1)
        #expect(host.newTerminalCalls[0].1 == anchorPanel)
        #expect(host.reorders.count == 1)
        #expect(host.reorders[0] == (created, 4))
    }

    @Test func createBrowserToRightInheritsAnchorProfileAndReorders() {
        let (coordinator, host, _, _) = make()
        let anchor = TabID()
        let anchorPanel = UUID()
        let pane = PaneID()
        let created = UUID()
        host.surfaceToPanel[anchor.uuid] = anchorPanel
        host.insertionIndex = 2
        host.newBrowserResult = created

        coordinator.createBrowserToRight(of: anchor, inPane: pane)

        #expect(host.newBrowserCalls[0].1 == anchorPanel)
        #expect(host.reorders[0] == (created, 2))
    }

    @Test func createToRightNoopWhenCreationFails() {
        let (coordinator, host, _, _) = make()
        host.newTerminalResult = nil
        coordinator.createTerminalToRight(of: TabID(), inPane: PaneID())
        #expect(host.reorders.isEmpty)
    }

    @Test func moveDestinationsPrependNewWorkspaceThenEncodeExistingTargets() {
        let (coordinator, host, _, _) = make()
        let tab = TabID()
        host.surfaceToPanel[tab.uuid] = UUID()
        let ws1 = UUID(), ws2 = UUID()
        host.moveTargets = [
            WorkspaceContextMoveTarget(workspaceId: ws1, label: "Alpha"),
            WorkspaceContextMoveTarget(workspaceId: ws2, label: "Beta"),
        ]

        let destinations = coordinator.moveDestinations(for: tab, newWorkspaceTitle: "New Workspace")

        #expect(destinations.count == 3)
        #expect(destinations[0].id == "new-workspace")
        #expect(destinations[0].title == "New Workspace")
        #expect(destinations[1].id == "workspace:\(ws1.uuidString)")
        #expect(destinations[1].title == "Alpha")
        #expect(destinations[2].id == "workspace:\(ws2.uuidString)")
    }

    @Test func moveDestinationsOmitNewWorkspaceWhenDisallowed() {
        let (coordinator, host, _, _) = make()
        let tab = TabID()
        host.surfaceToPanel[tab.uuid] = UUID()
        host.canMoveToNewWorkspace = false
        host.moveTargets = [WorkspaceContextMoveTarget(workspaceId: UUID(), label: "Alpha")]

        let destinations = coordinator.moveDestinations(for: tab, newWorkspaceTitle: "New Workspace")

        #expect(destinations.count == 1)
        #expect(destinations[0].title == "Alpha")
    }

    @Test func moveTabRoutesNewWorkspaceDestination() {
        let (coordinator, host, _, _) = make()
        let tab = TabID()
        let panel = UUID()
        host.surfaceToPanel[tab.uuid] = panel

        let moved = coordinator.moveTab(tab, toMoveDestination: "new-workspace")

        #expect(moved)
        #expect(host.movedToNewWorkspacePanels == [panel])
        #expect(host.moveFailureAlerts == 0)
    }

    @Test func moveTabRoutesExistingWorkspaceDestination() {
        let (coordinator, host, _, _) = make()
        let tab = TabID()
        let panel = UUID()
        let ws = UUID()
        host.surfaceToPanel[tab.uuid] = panel

        let moved = coordinator.moveTab(tab, toMoveDestination: "workspace:\(ws.uuidString)")

        #expect(moved)
        #expect(host.movedToExisting.count == 1)
        #expect(host.movedToExisting[0] == (panel, ws))
    }

    @Test func moveTabPresentsFailureAlertWhenMoveFails() {
        let (coordinator, host, _, _) = make()
        let tab = TabID()
        host.surfaceToPanel[tab.uuid] = UUID()
        host.moveToNewWorkspaceResult = false

        let moved = coordinator.moveTab(tab, toMoveDestination: "new-workspace")

        #expect(!moved)
        #expect(host.moveFailureAlerts == 1)
    }

    @Test func moveTabRejectsUnknownDestinationWithoutAlertOnInvalidWorkspaceId() {
        let (coordinator, host, _, _) = make()
        let tab = TabID()
        host.surfaceToPanel[tab.uuid] = UUID()

        // Invalid UUID after the prefix returns false WITHOUT presenting the
        // alert (the guard returns before the move/alert), matching legacy.
        let moved = coordinator.moveTab(tab, toMoveDestination: "workspace:not-a-uuid")

        #expect(!moved)
        #expect(host.moveFailureAlerts == 0)
    }

    @Test func moveTabUnknownDestinationPrefixPresentsFailureAlert() {
        let (coordinator, host, _, _) = make()
        let tab = TabID()
        host.surfaceToPanel[tab.uuid] = UUID()

        // A destination matching neither branch falls to `moved = false`, which
        // DOES present the failure alert (legacy behavior).
        let moved = coordinator.moveTab(tab, toMoveDestination: "garbage")

        #expect(!moved)
        #expect(host.moveFailureAlerts == 1)
    }
}
