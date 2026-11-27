import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite("Command palette workspace rename target resolution")
struct CommandPaletteWorkspaceRenameTargetTests {
    @Test("A focused group anchor renames the group, not the hidden anchor workspace")
    func anchorResolvesToGroup() {
        let anchorId = UUID()
        let groupId = UUID()
        let target = CommandPaletteRenameTarget(
            focusedWorkspaceId: anchorId,
            focusedWorkspaceName: "Group 3",
            groupAnchors: [
                CommandPaletteWorkspaceGroupAnchor(
                    groupId: groupId,
                    anchorWorkspaceId: anchorId,
                    name: "Swappa"
                )
            ]
        )

        #expect(target.kind == .workspaceGroup(groupId: groupId))
        // The group name the header row renders, not the stale anchor title.
        #expect(target.currentName == "Swappa")
    }

    @Test("A focused group member still renames that workspace")
    func memberResolvesToWorkspace() {
        let memberId = UUID()
        let target = CommandPaletteRenameTarget(
            focusedWorkspaceId: memberId,
            focusedWorkspaceName: "api",
            groupAnchors: [
                CommandPaletteWorkspaceGroupAnchor(
                    groupId: UUID(),
                    anchorWorkspaceId: UUID(),
                    name: "Swappa"
                )
            ]
        )

        #expect(target.kind == .workspace(workspaceId: memberId))
        #expect(target.currentName == "api")
    }

    @Test("An ungrouped workspace renames itself")
    func ungroupedResolvesToWorkspace() {
        let workspaceId = UUID()
        let target = CommandPaletteRenameTarget(
            focusedWorkspaceId: workspaceId,
            focusedWorkspaceName: "scratch",
            groupAnchors: []
        )

        #expect(target.kind == .workspace(workspaceId: workspaceId))
        #expect(target.currentName == "scratch")
    }
}
