import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func reorderReservationSurvivesHierarchySheetRecreation() throws {
    let store = MobileShellComposite.preview()
    let firstSheetGate = store.terminalReorderGate

    let reservation = try #require(
        firstSheetGate.reserve(workspaceID: "workspace", paneID: "pane-left")
    )

    let reopenedSheetGate = store.terminalReorderGate
    #expect(reopenedSheetGate === firstSheetGate)
    #expect(reopenedSheetGate.isActive)
    #expect(reopenedSheetGate.reserve(workspaceID: "workspace", paneID: "pane-right") == nil)

    reopenedSheetGate.finish(reservation)
    #expect(!firstSheetGate.isActive)
}

@MainActor
@Test func hierarchyMutationGateStaysClosedUntilRecoverySucceeds() throws {
    let gate = MobileTerminalReorderGate()
    let closeReservation = try #require(
        gate.reserve(workspaceID: "workspace", paneID: "pane-left")
    )

    #expect(gate.reserve(workspaceID: "workspace", paneID: "pane-right") == nil)
    gate.requireRefresh(workspaceID: "workspace")
    gate.finish(closeReservation)
    #expect(!gate.canMutate(workspaceID: "workspace"))
    #expect(gate.canMutate(workspaceID: "other-workspace"))

    #expect(!gate.beginRecovery(workspaceID: "other-workspace"))
    gate.requireRefresh(workspaceID: "other-workspace")
    #expect(gate.beginRecovery(workspaceID: "workspace"))
    gate.finishRecovery(workspaceID: "workspace", succeeded: false)
    #expect(!gate.canMutate(workspaceID: "workspace"))

    #expect(gate.beginRecovery(workspaceID: "workspace"))
    gate.finishRecovery(workspaceID: "workspace", succeeded: true)
    #expect(gate.canMutate(workspaceID: "workspace"))
    #expect(!gate.canMutate(workspaceID: "other-workspace"))

    #expect(gate.beginRecovery(workspaceID: "other-workspace"))
    gate.finishRecovery(workspaceID: "other-workspace", succeeded: true)
    #expect(gate.canMutate(workspaceID: "other-workspace"))
}

@MainActor
@Test func authoritativeRefreshReopensAndPrunesHierarchyMutationGates() {
    let gate = MobileTerminalReorderGate()
    gate.requireRefresh(workspaceID: "refreshed-workspace")
    gate.requireRefresh(workspaceID: "removed-workspace")
    gate.requireRefresh(workspaceID: "other-mac-workspace")

    gate.reconcileAfterAuthoritativeRefresh(
        workspaceIDs: ["refreshed-workspace", "removed-workspace"]
    )

    #expect(gate.canMutate(workspaceID: "refreshed-workspace"))
    #expect(gate.canMutate(workspaceID: "removed-workspace"))
    #expect(!gate.canMutate(workspaceID: "other-mac-workspace"))
}

@MainActor
@Test func remoteTerminalCreationSerializesWithCloseAndReorder() throws {
    let store = MobileShellComposite.preview()
    var workspace = try #require(store.workspaces.first)
    let paneID = MobilePanePreview.ID(rawValue: "pane-create")
    workspace.panes = [
        MobilePanePreview(
            id: paneID,
            spatialIndex: 0,
            terminalIDs: workspace.terminals.map(\.id)
        ),
    ]
    workspace.actionCapabilities = MobileWorkspaceActionCapabilities(
        supportsTerminalCloseActions: true,
        supportsTerminalCreateInPane: true,
        supportsTerminalReorderActions: true
    )

    let claim = store.claimTerminalCreationMutation(in: workspace, paneID: paneID)

    #expect(store.terminalReorderGate.isActive)
    #expect(store.terminalReorderGate.reserve(workspaceID: workspace.id, paneID: paneID) == nil)
    store.finishTerminalCreationMutation(claim)
    #expect(store.terminalReorderGate.canMutate(workspaceID: workspace.id))
}

@MainActor
@Test func rejectedReorderReleasesItsReservation() async throws {
    let store = MobileShellComposite.preview()
    let pane = MobilePanePreview(
        id: "missing-pane",
        spatialIndex: 0,
        terminalIDs: ["terminal-a", "terminal-b"]
    )
    let intent = try #require(MobileTerminalReorderIntent(
        terminalID: "terminal-a",
        sourceIndex: 0,
        destinationIndex: 2,
        pane: pane
    ))
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: "missing-workspace",
        paneID: pane.id
    ))

    _ = await store.reorderTerminal(
        workspaceID: "missing-workspace",
        intent: intent,
        reservation: reservation
    )

    #expect(store.terminalReorderGate.canMutate(workspaceID: "missing-workspace"))
}

@MainActor
@Test func rejectedCloseReleasesItsReservation() async throws {
    let store = MobileShellComposite.preview()
    let reservation = try #require(store.terminalReorderGate.reserve(
        workspaceID: "missing-workspace",
        paneID: "missing-pane"
    ))

    _ = await store.closeTerminal(
        workspaceID: "missing-workspace",
        terminalID: "missing-terminal",
        confirmed: false,
        reservation: reservation
    )

    #expect(store.terminalReorderGate.canMutate(workspaceID: "missing-workspace"))
}
