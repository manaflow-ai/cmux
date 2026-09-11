import Foundation
import Testing

@testable import CmuxWorkspaces

@MainActor
@Suite("Workspace cycle destinations")
struct WorkspaceCycleDestinationTests {
    /// Verifies focused-group cycling wraps through non-anchor members.
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

    /// Verifies an anchor enters the focused-group cycle from either direction.
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

    /// Verifies an ungrouped workspace uses the window order for focused-group scope.
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

    /// Verifies the explicit window scope retains flat tab-order behavior.
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

    /// Verifies an anchor-only group cannot produce a member destination.
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

    /// Verifies that cycling skips every row hidden inside a collapsed group.
    @Test("visible-row scope skips a collapsed group between visible workspaces")
    func visibleRowsSkipCollapsedGroup() {
        let fixture = makeFixture()
        fixture.model.workspaceGroups[0].isCollapsed = true

        #expect(fixture.model.cycleDestination(
            from: fixture.ungroupedBefore.id,
            direction: .next,
            scope: .visibleWorkspaceRows
        ) == fixture.ungroupedAfter.id)
        #expect(fixture.model.cycleDestination(
            from: fixture.ungroupedAfter.id,
            direction: .previous,
            scope: .visibleWorkspaceRows
        ) == fixture.ungroupedBefore.id)
    }

    /// Verifies that cycling from a hidden member exits toward the nearest visible row.
    @Test("visible-row scope exits a collapsed group in the requested direction")
    func visibleRowsExitCollapsedGroup() {
        let fixture = makeFixture()
        fixture.model.workspaceGroups[0].isCollapsed = true

        #expect(fixture.model.cycleDestination(
            from: fixture.firstMember.id,
            direction: .next,
            scope: .visibleWorkspaceRows
        ) == fixture.ungroupedAfter.id)
        #expect(fixture.model.cycleDestination(
            from: fixture.firstMember.id,
            direction: .previous,
            scope: .visibleWorkspaceRows
        ) == fixture.ungroupedBefore.id)
    }

    /// Verifies that unresolved group metadata cannot make a workspace appear visible.
    @Test("visible-row scope excludes workspaces whose group metadata is missing")
    func visibleRowsExcludeWorkspaceWithMissingGroup() {
        let ungroupedBefore = CoordinatorStubTab()
        let missingGroupMember = CoordinatorStubTab(groupId: UUID())
        let ungroupedAfter = CoordinatorStubTab()
        let model = WorkspacesModel<CoordinatorStubTab>()
        model.tabs = [ungroupedBefore, missingGroupMember, ungroupedAfter]

        #expect(model.cycleDestination(
            from: ungroupedBefore.id,
            direction: .next,
            scope: .visibleWorkspaceRows
        ) == ungroupedAfter.id)
        #expect(model.cycleDestination(
            from: ungroupedAfter.id,
            direction: .previous,
            scope: .visibleWorkspaceRows
        ) == ungroupedBefore.id)
        #expect(model.cycleDestination(
            from: missingGroupMember.id,
            direction: .next,
            scope: .visibleWorkspaceRows
        ) == ungroupedAfter.id)
    }

    /// Builds a tab order containing ungrouped rows around one expanded group.
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

    /// Builds the group metadata used by the cycle fixtures.
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
