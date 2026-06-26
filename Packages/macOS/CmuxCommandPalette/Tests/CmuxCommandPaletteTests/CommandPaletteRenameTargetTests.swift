import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite struct CommandPaletteRenameTargetTests {
    @Test func workspaceGroupTargetUsesGroupCopy() {
        let target = CommandPaletteRenameTarget(
            kind: .workspaceGroup(groupId: UUID()),
            currentName: "Backend"
        )

        #expect(target.title == "Rename Group")
        #expect(target.description == "Enter a new name for this group.")
        #expect(target.placeholder == "Group name")
        #expect(target.inputHint == "Enter a workspace group name. Press Enter to rename, Escape to cancel.")
        #expect(target.confirmHint == "Press Enter to apply this workspace group name, or Escape to cancel.")
    }
}
