import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
@Suite("Workspace panel color model")
struct WorkspacePanelColorModelTests {
    @Test("Assignments are normalized and exposed as value snapshots")
    func normalizesAssignments() {
        let panelID = UUID()
        let model = WorkspacePanelColorModel()

        #expect(model.setColor("#12ab34", forPanelID: panelID))
        #expect(model.color(forPanelID: panelID) == "#12AB34")
        #expect(model.snapshot == [panelID: "#12AB34"])
    }

    @Test("Invalid assignments preserve the existing color", arguments: [
        "+ABCDE",
        "-ABCDE",
        "#+ABCDE",
    ])
    func rejectsSignedHexColors(_ input: String) {
        let panelID = UUID()
        let model = WorkspacePanelColorModel()
        #expect(model.setColor("#7A4FD8", forPanelID: panelID))

        #expect(!model.setColor(input, forPanelID: panelID))
        #expect(model.color(forPanelID: panelID) == "#7A4FD8")
    }

    @Test("Clearing and retention affect only the requested panels")
    func clearsAndRetainsAssignments() {
        let retainedPanelID = UUID()
        let removedPanelID = UUID()
        let clearedPanelID = UUID()
        let model = WorkspacePanelColorModel()
        #expect(model.setColor("#112233", forPanelID: retainedPanelID))
        #expect(model.setColor("#445566", forPanelID: removedPanelID))
        #expect(model.setColor("#778899", forPanelID: clearedPanelID))

        #expect(model.setColor(nil, forPanelID: clearedPanelID))
        model.retainColors(forPanelIDs: [retainedPanelID])

        #expect(model.snapshot == [retainedPanelID: "#112233"])
    }
}
