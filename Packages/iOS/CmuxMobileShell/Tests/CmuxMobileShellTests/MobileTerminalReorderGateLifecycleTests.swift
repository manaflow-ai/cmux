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
    let unrelatedReservation = try #require(
        gate.reserve(workspaceID: "other-workspace", paneID: "pane-right")
    )
    gate.finish(unrelatedReservation)
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
@Test func hierarchyReservationsAreScopedToTheirWorkspace() throws {
    let gate = MobileTerminalReorderGate()
    let first = try #require(gate.reserve(
        workspaceID: "workspace-a",
        paneID: "pane-a"
    ))
    let second = try #require(gate.reserve(
        workspaceID: "workspace-b",
        paneID: "pane-b"
    ))

    #expect(!gate.canMutate(workspaceID: "workspace-a"))
    #expect(!gate.canMutate(workspaceID: "workspace-b"))
    #expect(gate.canMutate(workspaceID: "workspace-c"))

    gate.finish(first)
    #expect(gate.canMutate(workspaceID: "workspace-a"))
    #expect(!gate.canMutate(workspaceID: "workspace-b"))

    gate.finish(second)
    #expect(gate.canMutate(workspaceID: "workspace-b"))
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
