import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceMovePolicyTests {
    private func workspace(
        _ id: String,
        group: String? = nil,
        pinned: Bool = false
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            isPinned: pinned,
            groupID: group.map { .init(rawValue: $0) },
            terminals: []
        )
    }

    private func group(
        _ id: String,
        anchor: String,
        collapsed: Bool = false,
        pinned: Bool = false
    ) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: .init(rawValue: id),
            name: id,
            isCollapsed: collapsed,
            isPinned: pinned,
            anchorWorkspaceID: .init(rawValue: anchor)
        )
    }

    private func items(
        _ workspaces: [MobileWorkspacePreview],
        _ groups: [MobileWorkspaceGroupPreview]
    ) -> [MobileWorkspaceListItem] {
        MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
    }

    private func intent(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        sourceID: String,
        destination: Int
    ) -> MobileWorkspaceMoveIntent? {
        let rendered = items(workspaces, groups)
        guard let sourceIndex = rendered.firstIndex(where: { $0.id == sourceID }) else {
            Issue.record("Missing source row \(sourceID)")
            return nil
        }
        return rendered.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: sourceIndex),
            destination: destination
        )
    }

    private func movedIDs(
        _ workspaces: [MobileWorkspacePreview],
        _ moveIntent: MobileWorkspaceMoveIntent,
        movedWorkspaceID: MobileWorkspacePreview.ID,
        groups: [MobileWorkspaceGroupPreview]
    ) -> [String] {
        workspaces.applyingWorkspaceMoveIntent(
            moveIntent,
            movedWorkspaceID: movedWorkspaceID,
            groups: groups
        ).map(\.id.rawValue)
    }

    @Test func groupHeaderDroppedMidAnotherGroupNormalizesToWholeGroupBoundary() throws {
        let workspaces = [
            workspace("b-anchor", group: "b"),
            workspace("b-one", group: "b"),
            workspace("b-two", group: "b"),
            workspace("g-anchor", group: "g"),
            workspace("g-member", group: "g"),
            workspace("tail"),
        ]
        let groups = [group("b", anchor: "b-anchor"), group("g", anchor: "g-anchor")]
        let move = try #require(intent(
            workspaces: workspaces,
            groups: groups,
            sourceID: "group.g",
            destination: 2
        ))
        #expect(move == MobileWorkspaceMoveIntent(
            groupID: nil,
            beforeWorkspaceID: "b-anchor",
            movesGroup: true
        ))
        #expect(movedIDs(workspaces, move, movedWorkspaceID: "g-anchor", groups: groups) == [
            "g-anchor", "g-member", "b-anchor", "b-one", "b-two", "tail",
        ])
    }

    @Test func groupHeaderDroppedOnOwnMemberIsNoOp() {
        let workspaces = [workspace("anchor", group: "g"), workspace("member", group: "g"), workspace("tail")]
        let groups = [group("g", anchor: "anchor")]
        #expect(intent(workspaces: workspaces, groups: groups, sourceID: "group.g", destination: 2) == nil)
    }

    @Test func groupHeaderCanMoveToTopBottomAndBetweenRootRows() throws {
        let workspaces = [
            workspace("root-a"),
            workspace("root-b"),
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let toTop = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "group.g", destination: 0))
        #expect(toTop.beforeWorkspaceID == "root-a")
        let betweenRoots = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "group.g", destination: 1))
        #expect(betweenRoots.beforeWorkspaceID == "root-b")

        let bottomWorkspaces = [
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
            workspace("root-a"),
            workspace("root-b"),
        ]
        let toBottom = try #require(intent(
            workspaces: bottomWorkspaces,
            groups: groups,
            sourceID: "group.g",
            destination: items(bottomWorkspaces, groups).count
        ))
        #expect(toBottom.beforeWorkspaceID == nil)
    }

    @Test func groupHeaderCanMoveAboveAndBelowExpandedOrCollapsedHeaders() throws {
        let expanded = [
            workspace("a-anchor", group: "a"),
            workspace("a-member", group: "a"),
            workspace("b-anchor", group: "b"),
            workspace("b-member", group: "b"),
        ]
        let expandedGroups = [group("a", anchor: "a-anchor"), group("b", anchor: "b-anchor")]
        let aboveExpanded = try #require(intent(
            workspaces: expanded,
            groups: expandedGroups,
            sourceID: "group.b",
            destination: 0
        ))
        #expect(aboveExpanded.beforeWorkspaceID == "a-anchor")
        let collapsed = [
            workspace("a-anchor", group: "a"),
            workspace("a-member", group: "a"),
            workspace("b-anchor", group: "b"),
            workspace("b-member", group: "b"),
            workspace("c-anchor", group: "c"),
            workspace("c-member", group: "c"),
        ]
        let collapsedGroups = [
            group("a", anchor: "a-anchor", collapsed: true),
            group("b", anchor: "b-anchor", collapsed: true),
            group("c", anchor: "c-anchor", collapsed: true),
        ]
        let belowCollapsed = try #require(intent(
            workspaces: collapsed,
            groups: collapsedGroups,
            sourceID: "group.c",
            destination: 1
        ))
        #expect(belowCollapsed.beforeWorkspaceID == "b-anchor")
    }

    @Test func workspaceGroupSlotsMapHeaderMemberBoundaryAndCollapsedRules() throws {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("first", group: "g"),
            workspace("second", group: "g"),
            workspace("tail"),
            workspace("dragged"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let belowHeader = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "workspace.dragged", destination: 1))
        #expect(belowHeader == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "first"))
        let midGroup = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "workspace.dragged", destination: 2))
        #expect(midGroup == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "second"))
        let beforeEndSlot = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "workspace.dragged", destination: 3))
        #expect(beforeEndSlot == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "tail"))
        let afterEndSlot = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "workspace.dragged", destination: 4))
        #expect(afterEndSlot == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "tail"))
        let aboveHeader = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "workspace.dragged", destination: 0))
        #expect(aboveHeader == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "anchor"))

        let collapsedGroups = [group("g", anchor: "anchor", collapsed: true)]
        let belowCollapsedHeader = try #require(intent(
            workspaces: workspaces,
            groups: collapsedGroups,
            sourceID: "workspace.dragged",
            destination: 1
        ))
        #expect(belowCollapsedHeader == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "tail"))
    }

    @Test func expandedAnchorOnlyGroupAcceptsBelowHeaderSlot() throws {
        let workspaces = [workspace("anchor", group: "g"), workspace("tail"), workspace("dragged")]
        let groups = [group("g", anchor: "anchor")]
        let aboveHeader = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "workspace.dragged", destination: 0))
        #expect(aboveHeader == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "anchor"))
        let belowHeader = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "workspace.dragged", destination: 1))
        #expect(belowHeader == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "tail"))
    }

    @Test func movingLastNonAnchorMemberOutLeavesAnchorOnlyGroup() throws {
        let workspaces = [workspace("anchor", group: "g"), workspace("member", group: "g"), workspace("root")]
        let groups = [group("g", anchor: "anchor")]
        let move = try #require(intent(workspaces: workspaces, groups: groups, sourceID: "workspace.member", destination: 4))
        #expect(move == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: nil))
        let moved = workspaces.applyingWorkspaceMoveIntent(move, movedWorkspaceID: "member", groups: groups)
        #expect(moved.map(\.id.rawValue) == ["anchor", "root", "member"])
        #expect(moved.first(where: { $0.id == "anchor" })?.groupID == "g")
        #expect(moved.first(where: { $0.id == "member" })?.groupID == nil)
    }

    @Test func lastMemberBoundaryKeepsMembershipUntilBothNeighborsAreOutside() throws {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("first", group: "g"),
            workspace("last", group: "g"),
            workspace("root-a"),
            workspace("root-b"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let groupEnd = try #require(intent(
            workspaces: workspaces,
            groups: groups,
            sourceID: "workspace.first",
            destination: 3
        ))
        #expect(groupEnd == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "root-a"))
        #expect(movedIDs(workspaces, groupEnd, movedWorkspaceID: "first", groups: groups) == [
            "anchor", "last", "first", "root-a", "root-b",
        ])

        let directExit = try #require(intent(
            workspaces: workspaces,
            groups: groups,
            sourceID: "workspace.first",
            destination: 4
        ))
        #expect(directExit == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "root-a"))

        let outside = try #require(intent(
            workspaces: workspaces,
            groups: groups,
            sourceID: "workspace.first",
            destination: 5
        ))
        #expect(outside == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "root-b"))
    }

    @Test func pinnedWorkspaceAndGroupTopLevelMovesClampToTheirTier() throws {
        let workspaces = [
            workspace("p1", pinned: true),
            workspace("p2", pinned: true),
            workspace("u1"),
            workspace("u2"),
        ]
        let flatItems = workspaces.map { MobileWorkspaceListItem.workspace($0, indented: false) }
        let pinnedDown = try #require(flatItems.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet(integer: 0),
            destination: 4
        ))
        #expect(pinnedDown == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "u1"))
        #expect(movedIDs(workspaces, pinnedDown, movedWorkspaceID: "p1", groups: []) == ["p2", "p1", "u1", "u2"])

        let unpinnedUp = try #require(flatItems.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet(integer: 3),
            destination: 0
        ))
        #expect(unpinnedUp == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "u1"))

        let grouped = [
            workspace("ga", group: "g"),
            workspace("gm", group: "g"),
            workspace("pa", group: "p"),
            workspace("pm", group: "p"),
            workspace("ha", group: "h"),
            workspace("hm", group: "h"),
            workspace("root"),
        ]
        let groups = [
            group("g", anchor: "ga", pinned: true),
            group("p", anchor: "pa", pinned: true),
            group("h", anchor: "ha"),
        ]
        let groupMove = try #require(intent(
            workspaces: grouped,
            groups: groups,
            sourceID: "group.g",
            destination: items(grouped, groups).count
        ))
        #expect(groupMove.beforeWorkspaceID == "ha")
    }

    @Test func pinnedWorkspaceAfterLeadingPinnedGroupUsesWholePinnedTier() throws {
        let workspaces = [
            workspace("pa", group: "g"),
            workspace("pm", group: "g"),
            workspace("q1", pinned: true),
            workspace("q2", pinned: true),
            workspace("r"),
        ]
        let groups = [group("g", anchor: "pa", pinned: true)]
        let belowQ2 = try #require(intent(
            workspaces: workspaces,
            groups: groups,
            sourceID: "workspace.q1",
            destination: 5
        ))
        #expect(belowQ2.beforeWorkspaceID == "r")
        #expect(movedIDs(workspaces, belowQ2, movedWorkspaceID: "q1", groups: groups) == [
            "pa", "pm", "q2", "q1", "r",
        ])

        let belowUnpinnedRange = try #require(intent(
            workspaces: workspaces,
            groups: groups,
            sourceID: "workspace.q1",
            destination: items(workspaces, groups).count
        ))
        #expect(belowUnpinnedRange.beforeWorkspaceID == "r")
        #expect(movedIDs(workspaces, belowUnpinnedRange, movedWorkspaceID: "q1", groups: groups) == [
            "pa", "pm", "q2", "q1", "r",
        ])
    }

    @Test func inGroupPinnedMembersClampBelowAnchorAndAboveUnpinnedMembers() throws {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("pinned-a", group: "g", pinned: true),
            workspace("pinned-b", group: "g", pinned: true),
            workspace("plain", group: "g"),
            workspace("tail"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let pinnedDown = try #require(intent(
            workspaces: workspaces,
            groups: groups,
            sourceID: "workspace.pinned-a",
            destination: 4
        ))
        #expect(pinnedDown == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "plain"))
        let plainUp = intent(workspaces: workspaces, groups: groups, sourceID: "workspace.plain", destination: 1)
        #expect(plainUp == nil)
    }

    @Test func staleGroupAndUnknownBeforeWorkspaceNeverEmitDoomedIntent() {
        let workspaces = [workspace("stale", group: "missing"), workspace("root")]
        let rendered = items(workspaces, [])
        let move = rendered.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet(integer: 0),
            destination: 2
        )
        #expect(move == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: nil))

        let rejected = MobileWorkspaceMovePolicy(workspaces: workspaces, groups: []).normalizedIntent(
            MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "missing"),
            movedWorkspaceID: "root"
        )
        #expect(rejected == nil)
    }

    @Test func multiItemDestinationClampingAndIdentityMovesAreRejected() {
        let workspaces = [workspace("a"), workspace("b"), workspace("c")]
        let rendered = workspaces.map { MobileWorkspaceListItem.workspace($0, indented: false) }
        #expect(rendered.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet([0, 1]),
            destination: 3
        ) == nil)
        #expect(rendered.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet(integer: 1),
            destination: 2
        ) == nil)
        let clamped = rendered.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet(integer: 2),
            destination: -10
        )
        #expect(clamped == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "a"))
    }

}
