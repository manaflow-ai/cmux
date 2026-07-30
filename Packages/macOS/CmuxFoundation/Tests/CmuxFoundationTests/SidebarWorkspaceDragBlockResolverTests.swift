import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SidebarWorkspaceDragBlockResolverTests {
    private let resolver = SidebarWorkspaceDragBlockResolver()

    @Test func selectedMemberExpandsToTheSelection() {
        let ids = (0..<4).map { _ in UUID() }

        let movingIds = resolver.movingWorkspaceIds(
            orderedWorkspaceIds: ids,
            selectedIds: [ids[0], ids[2], ids[3]],
            draggedId: ids[2],
            anchorIds: []
        )

        #expect(movingIds == [ids[0], ids[2], ids[3]])
    }

    @Test func nonMemberMovesOnlyTheDraggedWorkspace() {
        let ids = (0..<3).map { _ in UUID() }

        let movingIds = resolver.movingWorkspaceIds(
            orderedWorkspaceIds: ids,
            selectedIds: [ids[0], ids[1]],
            draggedId: ids[2],
            anchorIds: []
        )

        #expect(movingIds == [ids[2]])
    }

    @Test func expandedSelectionExcludesGroupAnchors() {
        let ids = (0..<4).map { _ in UUID() }

        let movingIds = resolver.movingWorkspaceIds(
            orderedWorkspaceIds: ids,
            selectedIds: Set(ids),
            draggedId: ids[2],
            anchorIds: [ids[1]]
        )

        #expect(movingIds == [ids[0], ids[2], ids[3]])
    }

    @Test func selectedAnchorExpandsToSelectedAnchorsInSidebarOrder() {
        let ids = (0..<4).map { _ in UUID() }

        let movingIds = resolver.movingWorkspaceIds(
            orderedWorkspaceIds: ids,
            selectedIds: [ids[1], ids[3]],
            draggedId: ids[1],
            anchorIds: [ids[1], ids[3]]
        )

        #expect(movingIds == [ids[1], ids[3]])
    }

    @Test func nonSelectedAnchorMovesAlone() {
        let ids = (0..<3).map { _ in UUID() }

        let movingIds = resolver.movingWorkspaceIds(
            orderedWorkspaceIds: ids,
            selectedIds: [ids[0], ids[2]],
            draggedId: ids[1],
            anchorIds: [ids[1], ids[2]]
        )

        #expect(movingIds == [ids[1]])
    }

    @Test func anchorExpansionDropsStraySelectedWorkspaces() {
        let ids = (0..<5).map { _ in UUID() }

        let movingIds = resolver.movingWorkspaceIds(
            orderedWorkspaceIds: ids,
            selectedIds: [ids[0], ids[1], ids[2], ids[4]],
            draggedId: ids[2],
            anchorIds: [ids[0], ids[2], ids[4]]
        )

        #expect(movingIds == [ids[0], ids[2], ids[4]])
    }

    @Test func expandedSelectionUsesSidebarOrderInsteadOfSelectionOrder() {
        let ids = (0..<4).map { _ in UUID() }
        let selectedIds = Set([ids[3], ids[0], ids[2]])

        let movingIds = resolver.movingWorkspaceIds(
            orderedWorkspaceIds: ids,
            selectedIds: selectedIds,
            draggedId: ids[3],
            anchorIds: []
        )

        #expect(movingIds == [ids[0], ids[2], ids[3]])
    }
}
