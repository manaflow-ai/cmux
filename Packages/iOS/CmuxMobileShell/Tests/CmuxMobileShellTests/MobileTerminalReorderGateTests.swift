import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func reorderGateSurvivesHierarchySheetRecreation() {
    let store = MobileShellComposite.preview()
    let firstSheetGate = store.terminalReorderGate

    #expect(firstSheetGate.begin(workspaceID: "workspace", paneID: "pane-left"))

    let reopenedSheetGate = store.terminalReorderGate
    #expect(reopenedSheetGate === firstSheetGate)
    #expect(reopenedSheetGate.isActive)
    #expect(!reopenedSheetGate.begin(workspaceID: "workspace", paneID: "pane-right"))

    reopenedSheetGate.finish(workspaceID: "workspace", paneID: "pane-left")
    #expect(!firstSheetGate.isActive)
}
