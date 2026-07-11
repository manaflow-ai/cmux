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
