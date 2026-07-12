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
    gate.requireRefresh()
    gate.finish(closeReservation)
    #expect(!gate.canMutate)

    #expect(gate.beginRecovery())
    gate.finishRecovery(succeeded: false)
    #expect(!gate.canMutate)

    #expect(gate.beginRecovery())
    gate.finishRecovery(succeeded: true)
    #expect(gate.canMutate)
}
