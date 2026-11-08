import Foundation
import Testing

@testable import CmuxWorkspaces

@MainActor
@Suite("Workspace cycle destinations")
struct WorkspaceCycleDestinationTests {
    @Test("group scope wraps through members without selecting the anchor")
    func groupScopeWrapsThroughMembers() {
        let fixture = makeFixture()

        #expect(fixture.model.cycleDestination(
            from: fixture.firstMember.id,
            direction: .next,
            scope: .focusedGroupMembers
        ) == fixture.secondMember.id)
        #expect(fixture.model.cycleDestination(
            from: fixture.secondMember.id,
            direction: .next,
            scope: .focusedGroupMembers
        ) == fixture.firstMember.id)
        #expect(fixture.model.cycleDestination(
            from: fixture.firstMember.id,
            direction: .previous,
            scope: .focusedGroupMembers
        ) == fixture.secondMember.id)
    }

    @Test("group anchor enters the member cycle in the requested direction")
    func groupAnchorEntersMemberCycle() {
        let fixture = makeFixture()

        #expect(fixture.model.cycleDestination(
            from: fixture.anchor.id,
            direction: .next,
            scope: .focusedGroupMembers
        ) == fixture.firstMember.id)
        #expect(fixture.model.cycleDestination(
            from: fixture.anchor.id,
            direction: .previous,
            scope: .focusedGroupMembers
        ) == fixture.secondMember.id)
    }

    @Test("ungrouped workspace falls back to the window-wide order")
    func ungroupedWorkspaceFallsBackToWindowOrder() {
        let fixture = makeFixture()

        #expect(fixture.model.cycleDestination(
            from: fixture.ungroupedBefore.id,
            direction: .next,
            scope: .focusedGroupMembers
        ) == fixture.anchor.id)
        #expect(fixture.model.cycleDestination(
            from: fixture.ungroupedBefore.id,
            direction: .previous,
            scope: .focusedGroupMembers
        ) == fixture.ungroupedAfter.id)
    }

    @Test("window scope preserves flat cycling across group boundaries")
    func windowScopePreservesFlatCycling() {
        let fixture = makeFixture()

        #expect(fixture.model.cycleDestination(
            from: fixture.ungroupedBefore.id,
            direction: .next,
            scope: .window
        ) == fixture.anchor.id)
        #expect(fixture.model.cycleDestination(
            from: fixture.secondMember.id,
            direction: .next,
            scope: .window
        ) == fixture.ungroupedAfter.id)
    }

    @Test("group with only an anchor has no member destination")
    func anchorOnlyGroupHasNoDestination() {
        let groupId = UUID()
        let anchor = CoordinatorStubTab(groupId: groupId)
        let model = WorkspacesModel<CoordinatorStubTab>()
        model.tabs = [anchor]
        model.workspaceGroups = [workspaceGroup(
            id: groupId,
            anchorWorkspaceId: anchor.id
        )]

        #expect(model.cycleDestination(
            from: anchor.id,
            direction: .next,
            scope: .focusedGroupMembers
        ) == nil)
        #expect(model.cycleDestination(
            from: anchor.id,
            direction: .previous,
            scope: .focusedGroupMembers
        ) == nil)
    }

    private func makeFixture() -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        ungroupedBefore: CoordinatorStubTab,
        anchor: CoordinatorStubTab,
        firstMember: CoordinatorStubTab,
        secondMember: CoordinatorStubTab,
        ungroupedAfter: CoordinatorStubTab
    ) {
        let groupId = UUID()
        let ungroupedBefore = CoordinatorStubTab()
        let anchor = CoordinatorStubTab(groupId: groupId)
        let firstMember = CoordinatorStubTab(groupId: groupId)
        let secondMember = CoordinatorStubTab(groupId: groupId)
        let ungroupedAfter = CoordinatorStubTab()
        let model = WorkspacesModel<CoordinatorStubTab>()
        model.tabs = [
            ungroupedBefore,
            anchor,
            firstMember,
            secondMember,
            ungroupedAfter,
        ]
        model.workspaceGroups = [workspaceGroup(
            id: groupId,
            anchorWorkspaceId: anchor.id
        )]
        return (
            model,
            ungroupedBefore,
            anchor,
            firstMember,
            secondMember,
            ungroupedAfter
        )
    }

    private func workspaceGroup(id: UUID, anchorWorkspaceId: UUID) -> WorkspaceGroup {
        WorkspaceGroup(
            id: id,
            name: "Group",
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: anchorWorkspaceId,
            customColor: nil,
            iconSymbol: nil
        )
    }
}
