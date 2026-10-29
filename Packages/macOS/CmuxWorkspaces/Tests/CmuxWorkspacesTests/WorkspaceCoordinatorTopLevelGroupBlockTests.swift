import Foundation
import Testing

@testable import CmuxWorkspaces

/// Multi-selection drops of whole workspace-group sections in top-level row space.
@MainActor
struct WorkspaceCoordinatorTopLevelGroupBlockTests {
    private func makeFixture() throws -> WorkspaceCoordinatorTopLevelGroupBlockFixture {
        try WorkspaceCoordinatorTopLevelGroupBlockFixture()
    }

    @Test
    func selectedGroupsMoveAsContiguousSectionsAfterLooseRow() throws {
        let fixture = try makeFixture()
        let publicationCount = fixture.host.orderChanges.count
        let memberships = Dictionary(uniqueKeysWithValues: fixture.model.tabs.map {
            ($0.id, $0.groupId)
        })
        // targetIndex is the gap after loose1 in TOP-LEVEL space minus
        // dragged anchor1: [anchor2, loose1, loose2, loose3].
        let targetIndex = 2

        #expect(fixture.reorder.reorderSidebarWorkspaces(
            tabIds: [fixture.anchor1Id, fixture.anchor2Id],
            draggedTabId: fixture.anchor1Id,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: true
        ))
        #expect(fixture.model.tabs.map(\.id) == [
            fixture.loose1.id,
            fixture.anchor1Id,
            fixture.group1Child1.id,
            fixture.group1Child2.id,
            fixture.anchor2Id,
            fixture.group2Child.id,
            fixture.loose2.id,
            fixture.loose3.id,
        ])
        #expect(fixture.model.tabs.allSatisfy { memberships[$0.id] == $0.groupId })
        #expect(fixture.host.orderChanges.count == publicationCount + 1)
        #expect(Set(fixture.host.orderChanges.last ?? []) == [
            fixture.anchor1Id,
            fixture.group1Child1.id,
            fixture.group1Child2.id,
            fixture.anchor2Id,
            fixture.group2Child.id,
        ])
    }

    @Test
    func pastEndTargetAppendsSelectedGroups() throws {
        let fixture = try makeFixture()
        // targetIndex is the past-end gap in TOP-LEVEL space minus dragged
        // anchor1: [anchor2, loose1, loose2, loose3].
        let targetIndex = 4

        #expect(fixture.reorder.reorderSidebarWorkspaces(
            tabIds: [fixture.anchor1Id, fixture.anchor2Id],
            draggedTabId: fixture.anchor1Id,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: true
        ))
        #expect(fixture.model.tabs.map(\.id) == [
            fixture.loose1.id,
            fixture.loose2.id,
            fixture.loose3.id,
            fixture.anchor1Id,
            fixture.group1Child1.id,
            fixture.group1Child2.id,
            fixture.anchor2Id,
            fixture.group2Child.id,
        ])
    }

    @Test
    func ownBoundaryDropIsHandledNoOpWithoutPublication() throws {
        let fixture = try makeFixture()
        let before = fixture.model.tabs.map(\.id)
        let publicationCount = fixture.host.orderChanges.count
        // targetIndex is the block's own bottom boundary in TOP-LEVEL space
        // minus dragged anchor1: [anchor2, loose1, loose2, loose3].
        let targetIndex = 1

        #expect(fixture.reorder.reorderSidebarWorkspaces(
            tabIds: [fixture.anchor1Id, fixture.anchor2Id],
            draggedTabId: fixture.anchor1Id,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: true
        ))
        #expect(fixture.model.tabs.map(\.id) == before)
        #expect(fixture.host.orderChanges.count == publicationCount)
    }

    @Test
    func mixedPinTiersClampEachSelectedGroupIntoItsTier() throws {
        let fixture = try makeFixture()
        fixture.groups.setWorkspaceGroupPinned(
            groupId: fixture.group1Id,
            isPinned: true
        )
        let publicationCount = fixture.host.orderChanges.count
        // targetIndex is the past-end gap in TOP-LEVEL space minus dragged
        // anchor1: [anchor2, loose1, loose2, loose3].
        let targetIndex = 4

        #expect(fixture.reorder.reorderSidebarWorkspaces(
            tabIds: [fixture.anchor1Id, fixture.anchor2Id],
            draggedTabId: fixture.anchor1Id,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: true
        ))
        #expect(fixture.model.tabs.map(\.id) == [
            fixture.anchor1Id,
            fixture.group1Child1.id,
            fixture.group1Child2.id,
            fixture.loose1.id,
            fixture.loose2.id,
            fixture.loose3.id,
            fixture.anchor2Id,
            fixture.group2Child.id,
        ])
        #expect(fixture.model.tabs.filter { $0.groupId == fixture.group1Id }.map(\.id) == [
            fixture.anchor1Id,
            fixture.group1Child1.id,
            fixture.group1Child2.id,
        ])
        #expect(fixture.model.tabs.filter { $0.groupId == fixture.group2Id }.map(\.id) == [
            fixture.anchor2Id,
            fixture.group2Child.id,
        ])
        #expect(fixture.host.orderChanges.count == publicationCount + 1)
    }

    @Test
    func movingReferenceWalksToNextNonMovingTopLevelRow() throws {
        let fixture = try makeFixture()
        fixture.model.normalizeWorkspaceGroupRunsPreservingOrder([
            fixture.anchor1Id,
            fixture.loose1.id,
            fixture.anchor2Id,
            fixture.loose2.id,
            fixture.loose3.id,
        ])
        fixture.model.syncWorkspaceGroupsOrderToAnchorOrder()
        try #require(fixture.model.tabs.map(\.id) == [
            fixture.anchor1Id,
            fixture.group1Child1.id,
            fixture.group1Child2.id,
            fixture.loose1.id,
            fixture.anchor2Id,
            fixture.group2Child.id,
            fixture.loose2.id,
            fixture.loose3.id,
        ])
        // targetIndex 0 references moving anchor1 in TOP-LEVEL space minus
        // dragged anchor2: [anchor1, loose1, loose2, loose3], so resolution
        // walks forward to loose1.
        let targetIndex = 0

        #expect(fixture.reorder.reorderSidebarWorkspaces(
            tabIds: [fixture.anchor1Id, fixture.anchor2Id],
            draggedTabId: fixture.anchor2Id,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: true
        ))
        #expect(fixture.model.tabs.map(\.id) == [
            fixture.anchor1Id,
            fixture.group1Child1.id,
            fixture.group1Child2.id,
            fixture.anchor2Id,
            fixture.group2Child.id,
            fixture.loose1.id,
            fixture.loose2.id,
            fixture.loose3.id,
        ])
    }
}
