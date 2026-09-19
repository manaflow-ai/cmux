import Foundation
import Testing
@testable import CmuxWorkspaces

extension WorkspaceCoordinatorTests {
    @Test
    func moveTabsToBottomKeepsPinnedTierAboveUnpinned() {
        let (model, host, _, reorder) = makeWorld()
        let pinnedA = CoordinatorStubTab(isPinned: true)
        let pinnedB = CoordinatorStubTab(isPinned: true)
        let plain1 = CoordinatorStubTab()
        let plain2 = CoordinatorStubTab()
        model.tabs = [pinnedA, pinnedB, plain1, plain2]
        reorder.moveTabsToBottom([plain1.id, pinnedA.id])
        // Each selection sinks to the end of its own tier; tiers stay separated.
        #expect(model.tabs.map(\.id) == [pinnedB.id, pinnedA.id, plain2.id, plain1.id])
        #expect(host.orderChanges.last?.sorted(by: { $0.uuidString < $1.uuidString })
            == [pinnedA.id, plain1.id].sorted(by: { $0.uuidString < $1.uuidString }))
    }

    @Test
    func moveTabToBottomSinksSingleRowWithinItsTier() {
        let (model, _, _, reorder) = makeWorld()
        let plain1 = CoordinatorStubTab()
        let plain2 = CoordinatorStubTab()
        let plain3 = CoordinatorStubTab()
        model.tabs = [plain1, plain2, plain3]
        reorder.moveTabToBottom(plain1.id)
        #expect(model.tabs.map(\.id) == [plain2.id, plain3.id, plain1.id])
    }

    @Test
    func moveTabToBottomOnLastRowPublishesNoOrderChange() {
        let (model, host, _, reorder) = makeWorld()
        let plain1 = CoordinatorStubTab()
        let plain2 = CoordinatorStubTab()
        model.tabs = [plain1, plain2]
        let before = host.orderChanges.count
        reorder.moveTabToBottom(plain2.id)
        #expect(model.tabs.map(\.id) == [plain1.id, plain2.id])
        #expect(host.orderChanges.count == before)
    }

    @Test
    func moveToBottomSinksGroupedChildrenAndKeepsAnchorFirst() throws {
        let (model, host, groups, reorder) = makeWorld()
        let first = CoordinatorStubTab()
        let middle = CoordinatorStubTab()
        let last = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [first, middle, last, outside]
        let groupId = try #require(groups.createWorkspaceGroup(
            name: "G", childWorkspaceIds: [first.id, middle.id, last.id]
        ))
        let anchorId = try #require(model.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId)

        reorder.moveTabsToBottom([first.id, middle.id])

        #expect(model.tabs.map(\.id) == [outside.id, anchorId, last.id, first.id, middle.id])
        #expect([first, middle, last].allSatisfy { $0.groupId == groupId })
        let changes = host.orderChanges.count
        reorder.moveTabsToBottom([first.id, middle.id])
        #expect(host.orderChanges.count == changes)

        reorder.moveTabToTop(middle.id)
        #expect(model.tabs.map(\.id) == [anchorId, middle.id, last.id, first.id, outside.id])
    }

}
