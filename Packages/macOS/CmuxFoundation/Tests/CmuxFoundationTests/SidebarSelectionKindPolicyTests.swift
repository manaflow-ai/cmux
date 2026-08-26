import Foundation
import Testing

@testable import CmuxFoundation

@Suite
struct SidebarSelectionKindPolicyTests {
    private let policy = SidebarSelectionKindPolicy()

    @Test
    func workspaceCommandClickPurgesAnchorsBeforeToggling() {
        let workspaceId = UUID()
        let clickedId = UUID()
        let anchorIds = Set([UUID(), UUID()])

        let selectedIds = policy.workspaceCmdClickSelection(
            current: anchorIds.union([workspaceId]),
            clickedId: clickedId,
            anchorIds: anchorIds
        )

        #expect(selectedIds == [workspaceId, clickedId])
    }

    @Test
    func anchorCommandClickPurgesWorkspacesBeforeToggling() {
        let selectedAnchorId = UUID()
        let clickedAnchorId = UUID()
        let workspaceId = UUID()
        let anchorIds = Set([selectedAnchorId, clickedAnchorId])

        let selectedIds = policy.anchorCmdClickSelection(
            current: [workspaceId, selectedAnchorId],
            clickedAnchorId: clickedAnchorId,
            anchorIds: anchorIds
        )

        #expect(selectedIds == anchorIds)
    }

    @Test
    func anchorCommandClickCanToggleTheOnlyAnchorOff() {
        let anchorId = UUID()

        let selectedIds = policy.anchorCmdClickSelection(
            current: [anchorId],
            clickedAnchorId: anchorId,
            anchorIds: [anchorId]
        )

        #expect(selectedIds.isEmpty)
    }

    @Test
    func workspaceShiftRangeDropsAnchors() {
        let ids = (0..<4).map { _ in UUID() }

        let rangeIds = policy.workspaceShiftRangeIds(
            rangeIds: ids,
            anchorIds: [ids[1], ids[3]]
        )

        #expect(rangeIds == [ids[0], ids[2]])
    }
}
