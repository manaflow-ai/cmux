import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class DividerStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    let currentDirectory = "/tmp"

    init(id: UUID = UUID(), groupId: UUID? = nil, isPinned: Bool = false) {
        self.id = id
        self.groupId = groupId
        self.isPinned = isPinned
    }
}

@MainActor
struct WorkspaceSidebarDividerTests {
    @Test
    func insertionRejectsLeadingTrailingAndAdjacentDividers() {
        let model = WorkspacesModel<DividerStubTab>()
        let first = DividerStubTab()
        let second = DividerStubTab()
        let third = DividerStubTab()
        model.tabs = [first, second, third]

        #expect(model.insertSidebarDivider(before: first.id) == nil)
        #expect(model.insertSidebarDivider(after: third.id) == nil)
        let dividerId = model.insertSidebarDivider(after: first.id)
        #expect(dividerId != nil)
        #expect(model.insertSidebarDivider(after: first.id) == nil)
        #expect(model.sidebarDividers.map(\.id) == [dividerId].compactMap { $0 })
    }

    @Test
    func addDividerUsesLastAvailableInteriorGap() throws {
        let model = WorkspacesModel<DividerStubTab>()
        let workspaces = (0..<4).map { _ in DividerStubTab() }
        model.tabs = workspaces
        _ = model.insertSidebarDivider(after: workspaces[2].id)

        let dividerId = try #require(model.insertSidebarDividerAtEnd())
        #expect(model.sidebarDivider(after: workspaces[1].id)?.id == dividerId)
    }

    @Test
    func movingAndRemovingDividerDoesNotChangeWorkspaceOrder() throws {
        let model = WorkspacesModel<DividerStubTab>()
        let first = DividerStubTab()
        let second = DividerStubTab()
        let third = DividerStubTab()
        model.tabs = [first, second, third]
        let dividerId = try #require(model.insertSidebarDivider(after: first.id))
        let originalWorkspaceOrder = model.tabs.map(\.id)

        #expect(model.moveSidebarDivider(id: dividerId, after: second.id))
        #expect(model.tabs.map(\.id) == originalWorkspaceOrder)
        #expect(model.sidebarDivider(after: second.id)?.id == dividerId)
        #expect(model.removeSidebarDivider(id: dividerId))
        #expect(model.sidebarDividers.isEmpty)
        #expect(model.tabs.map(\.id) == originalWorkspaceOrder)
    }

    @Test
    func staleAndDuplicatePlacementsNormalizeToOneValidGap() {
        let model = WorkspacesModel<DividerStubTab>()
        let first = DividerStubTab()
        let second = DividerStubTab()
        let third = DividerStubTab()
        model.tabs = [first, second, third]
        let firstDivider = WorkspaceSidebarDivider(afterWorkspaceId: first.id)
        let duplicate = WorkspaceSidebarDivider(afterWorkspaceId: first.id)
        let trailing = WorkspaceSidebarDivider(afterWorkspaceId: third.id)
        model.sidebarDividers = [firstDivider, duplicate, trailing]

        #expect(model.sidebarDividers == [firstDivider])
    }

    @Test
    func dividerFollowsAGroupWhenItsAnchorIsPromoted() {
        let model = WorkspacesModel<DividerStubTab>()
        let anchor = DividerStubTab()
        let member = DividerStubTab()
        let outside = DividerStubTab()
        let groupId = UUID()
        anchor.groupId = groupId
        member.groupId = groupId
        model.tabs = [anchor, member, outside]
        model.workspaceGroups = [WorkspaceGroup(
            id: groupId,
            name: "Group",
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: anchor.id,
            customColor: nil,
            iconSymbol: nil
        )]
        _ = model.insertSidebarDivider(after: anchor.id)

        model.tabs.removeFirst()
        model.workspaceGroups[0].anchorWorkspaceId = member.id

        #expect(model.sidebarDivider(after: member.id) != nil)
        #expect(model.sidebarDividers.count == 1)
    }

    @Test
    func closingGroupAnchorPreservesDividerAfterPromotedAnchor() throws {
        let model = WorkspacesModel<DividerStubTab>()
        let anchor = DividerStubTab()
        let member = DividerStubTab()
        let outside = DividerStubTab()
        let groupId = UUID()
        anchor.groupId = groupId
        member.groupId = groupId
        model.tabs = [anchor, member, outside]
        model.workspaceGroups = [WorkspaceGroup(
            id: groupId,
            name: "Group",
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: anchor.id,
            customColor: nil,
            iconSymbol: nil
        )]
        _ = try #require(model.insertSidebarDivider(after: anchor.id))

        let promoted = model.removeWorkspaceAndPromoteGroupAnchor(closedWorkspaceId: anchor.id)

        #expect(promoted == [member.id])
        #expect(model.tabs.map(\.id) == [member.id, outside.id])
        #expect(model.sidebarDivider(after: member.id) != nil)
    }
}
