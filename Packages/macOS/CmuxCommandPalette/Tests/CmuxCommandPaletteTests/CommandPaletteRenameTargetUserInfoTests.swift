import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite("Command palette rename target payload")
struct CommandPaletteRenameTargetUserInfoTests {
    @Test("Every target kind survives the rename request payload")
    func roundTrips() {
        let targets = [
            CommandPaletteRenameTarget(kind: .workspace(workspaceId: UUID()), currentName: "api"),
            CommandPaletteRenameTarget(kind: .tab(workspaceId: UUID(), panelId: UUID()), currentName: "zsh"),
            CommandPaletteRenameTarget(kind: .workspaceGroup(groupId: UUID()), currentName: "Swappa"),
        ]
        for target in targets {
            #expect(CommandPaletteRenameTarget(userInfo: target.userInfo) == target)
        }
    }

    @Test("A request without a target payload is ignored")
    func missingPayloadIsNil() {
        #expect(CommandPaletteRenameTarget(userInfo: nil) == nil)
        #expect(CommandPaletteRenameTarget(userInfo: [:]) == nil)
        #expect(CommandPaletteRenameTarget(userInfo: ["cmux.commandPaletteRenameTarget": "zsh"]) == nil)
    }
}
