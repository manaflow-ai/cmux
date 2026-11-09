@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextHomeEngine
import Foundation
import Testing

/// Archive Chief, Make Primary Chief and Delete Chief… have a palette row that picks the Chief
/// (cmuxterm-hq goals/palette-all-actions.md: every CLI action has a palette entry), where `cmux home
/// archive-chief|primary-chief|delete-chief` takes its id.
@MainActor @Suite struct HomeChiefPaletteSuggestionsTests {
    @Test func theChiefActionsAreInThePaletteWithAChiefPick() {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["home.archiveChief", "home.setPrimaryChief", "home.deleteChief"] {
            let descriptor = registry.descriptor(for: id)
            #expect(descriptor?.isPaletteVisible == true, "\(id)")
            #expect(descriptor?.arguments.first { $0.name == "chief" }?.suggestions?.source == ActionSuggestions.homeChiefs, "\(id)")
        }
    }

    @Test func thePickListsTheChiefsPrimaryFirstByID() async {
        let chiefs: [[String: Any]] = [
            ["id": "agent_muse", "display_name": "Muse", "is_default": false, "rev": 5, "main_conversation": "conv_muse", "archived_at": NSNull()],
            ["id": "agent_ada", "display_name": "Ada", "is_default": true, "rev": 3, "main_conversation": "conv_ada", "archived_at": NSNull()],
        ]
        let directory = HomeDirectory(call: { _, body in
            body["op"] as? String == "chief.list" ? ["ok": true, "value": ["chiefs": chiefs]] : ["ok": true]
        }, me: { nil })
        await directory.refreshChiefs()
        #expect(directory.chiefSuggestions() == [ActionEnumCase(value: "agent_ada", title: "Ada"),
                                                 ActionEnumCase(value: "agent_muse", title: "Muse")])
    }
}
