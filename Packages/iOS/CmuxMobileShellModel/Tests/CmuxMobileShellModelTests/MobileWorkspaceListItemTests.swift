import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceListItemTests {
    private func workspace(
        _ id: String,
        group: String? = nil,
        unread: Bool = false,
        unreadCount: Int? = nil
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            groupID: group.map { .init(rawValue: $0) },
            hasUnread: unread,
            unreadCount: unreadCount,
            terminals: []
        )
    }

    private func group(
        _ id: String,
        anchor: String? = nil,
        collapsed: Bool = false,
        pinned: Bool = false,
        name: String? = nil,
        isEmpty: Bool = false
    ) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: .init(rawValue: id),
            name: name ?? id,
            isCollapsed: collapsed,
            isPinned: pinned,
            anchorWorkspaceID: anchor.map { .init(rawValue: $0) },
            isEmpty: isEmpty
        )
    }

    @Test func ungroupedWorkspacesRenderFlatInOrder() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a"), workspace("b")],
            groups: []
        )
        #expect(items == [
            .workspace(workspace("a"), indented: false),
            .workspace(workspace("b"), indented: false),
        ])
    }

    @Test func anchorRendersAsHeaderNotARow() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "g"), workspace("b", group: "g")],
            groups: [group("g", anchor: "a")]
        )
        #expect(items == [
            .groupHeader(group("g", anchor: "a"), unread: .read),
            .workspace(workspace("b", group: "g"), indented: true),
            .groupFooter("g"),
        ])
    }

    @Test func collapsedGroupHidesMembersButKeepsHeader() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "g"), workspace("b", group: "g")],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [.groupHeader(group("g", anchor: "a", collapsed: true), unread: .read)])
    }

    @Test func ungroupedAndGroupedInterleaveByPosition() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("top"),
                workspace("anchor", group: "g"),
                workspace("member", group: "g"),
                workspace("bottom"),
            ],
            groups: [group("g", anchor: "anchor")]
        )
        #expect(items == [
            .workspace(workspace("top"), indented: false),
            .groupHeader(group("g", anchor: "anchor"), unread: .read),
            .workspace(workspace("member", group: "g"), indented: true),
            .groupFooter("g"),
            .workspace(workspace("bottom"), indented: false),
        ])
    }

    @Test func unknownGroupIDDegradesToUngroupedRow() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "missing")],
            groups: []
        )
        #expect(items == [.workspace(workspace("a", group: "missing"), indented: false)])
    }

    @Test func anchorOnlyGroupRendersOnlyHeader() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "g")],
            groups: [group("g", anchor: "a")]
        )
        #expect(items == [.groupHeader(group("g", anchor: "a"), unread: .read)])
    }

    @Test func emptyGroupRendersHeaderWithoutWorkspaceRows() {
        let empty = group("empty", pinned: true, isEmpty: true)
        let items = MobileWorkspaceListItem.items(
            workspaces: [],
            groups: [empty]
        )
        #expect(items == [.groupHeader(empty, unread: .read)])
    }

    @Test func optimisticMemberPromotesStaleEmptyGroupHeader() {
        let staleEmptyGroup = group("group", pinned: true, isEmpty: true)
        let predictedMember = workspace("member", group: "group")
        let items = MobileWorkspaceListItem.items(
            workspaces: [predictedMember],
            groups: [staleEmptyGroup]
        )

        let effectiveGroup = group(
            "group",
            anchor: "member",
            pinned: true
        )
        #expect(items == [
            .groupHeader(effectiveGroup, unread: .read),
        ])
    }

    @Test func emptyPinnedHeaderStaysOutsidePinnedGroupMembers() {
        let liveGroup = group("live", anchor: "anchor", pinned: true)
        let emptyGroup = group("empty", pinned: true, isEmpty: true)
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("anchor", group: "live"),
                workspace("child", group: "live"),
                workspace("outside"),
            ],
            groups: [liveGroup, emptyGroup]
        )
        #expect(items == [
            .groupHeader(liveGroup, unread: .read),
            .workspace(workspace("child", group: "live"), indented: true),
            .groupFooter("live"),
            .groupHeader(emptyGroup, unread: .read),
            .workspace(workspace("outside"), indented: false),
        ])
    }

    @Test func populatedExpandedGroupEndsWithItsDropSlot() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "g"), workspace("b", group: "g")],
            groups: [group("g", anchor: "a")]
        )
        #expect(items.last == .groupFooter("g"))
    }

    @Test func collapsedGroupHeaderCarriesMemberUnread() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g"),
                workspace("b", group: "g", unread: true),
            ],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [.groupHeader(group("g", anchor: "a", collapsed: true), unread: .init(isUnread: true, count: nil))])
    }

    @Test func collapsedGroupHeaderCarriesAnchorUnread() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g", unread: true),
                workspace("b", group: "g"),
            ],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [.groupHeader(group("g", anchor: "a", collapsed: true), unread: .init(isUnread: true, count: nil))])
    }

    @Test func expandedGroupHeaderReflectsOnlyTheAnchor() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g"),
                workspace("b", group: "g", unread: true),
            ],
            groups: [group("g", anchor: "a")]
        )
        #expect(items == [
            .groupHeader(group("g", anchor: "a"), unread: .read),
            .workspace(workspace("b", group: "g", unread: true), indented: true),
            .groupFooter("g"),
        ])
    }

    @Test func expandedGroupHeaderCarriesUnreadAnchor() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g", unread: true),
                workspace("b", group: "g"),
            ],
            groups: [group("g", anchor: "a")]
        )
        #expect(items == [
            .groupHeader(group("g", anchor: "a"), unread: .init(isUnread: true, count: nil)),
            .workspace(workspace("b", group: "g"), indented: true),
            .groupFooter("g"),
        ])
    }

    @Test func collapsedGroupHeaderSumsMemberCounts() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g", unread: true, unreadCount: 2),
                workspace("b", group: "g", unread: true, unreadCount: 3),
                workspace("c", group: "g"),
            ],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [
            .groupHeader(
                group("g", anchor: "a", collapsed: true),
                unread: .init(isUnread: true, count: 5)
            ),
        ])
    }

    @Test func expandedGroupHeaderUsesAnchorCountOnly() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g", unread: true, unreadCount: 2),
                workspace("b", group: "g", unread: true, unreadCount: 3),
            ],
            groups: [group("g", anchor: "a")]
        )
        #expect(items.first == .groupHeader(
            group("g", anchor: "a"),
            unread: .init(isUnread: true, count: 2)
        ))
    }

    @Test func collapsedHeaderCountUnknownWhenAnyUnreadMemberLacksCount() {
        // One member reports a count, the other only the boolean (old Mac):
        // the aggregate must fall back to the count-less dot instead of
        // undercounting hidden activity.
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g", unread: true, unreadCount: 2),
                workspace("b", group: "g", unread: true),
            ],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [
            .groupHeader(
                group("g", anchor: "a", collapsed: true),
                unread: .init(isUnread: true, count: nil)
            ),
        ])
    }

    @Test func collapsedHeaderAggregatesNonContiguousMembers() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g"),
                workspace("mid"),
                workspace("b", group: "g", unread: true),
            ],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [
            .groupHeader(group("g", anchor: "a", collapsed: true), unread: .init(isUnread: true, count: nil)),
            .workspace(workspace("mid"), indented: false),
        ])
    }

    @Test func listMoveIntentAdjustsDownwardDestinationBeforeRemoval() {
        let workspaces = [workspace("a"), workspace("b"), workspace("c")]
        let items = workspaces.map { MobileWorkspaceListItem.workspace($0, indented: false) }
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet(integer: 0),
            destination: 3
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: nil))
    }

    @Test func listMoveIntentMovesUpwardBeforeTargetWorkspace() {
        let workspaces = [workspace("a"), workspace("b"), workspace("c")]
        let items = workspaces.map { MobileWorkspaceListItem.workspace($0, indented: false) }
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet(integer: 2),
            destination: 0
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "a"))
    }

    @Test func listMoveIntentLandingBelowExpandedHeaderJoinsGroupAtTop() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
            workspace("dragged"),
            workspace("tail"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 3),
            destination: 1
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "member"))
    }

    @Test func listMoveIntentGapAboveLeadingHeaderStaysTopLevel() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
            workspace("dragged"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 3),
            destination: 0
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "anchor"))
    }

    @Test func externalWorkspaceAtMixedGroupBoundaryStaysRoot() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("first", group: "g"),
            workspace("second", group: "g"),
            workspace("between"),
            workspace("dragged"),
            workspace("tail"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 5),
            destination: 4
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "between"))
    }

    @Test func externalWorkspaceBeforeGroupEndSlotJoinsGroup() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("first", group: "g"),
            workspace("second", group: "g"),
            workspace("between"),
            workspace("dragged"),
            workspace("tail"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 5),
            destination: 3
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "between"))
    }

    @Test func currentGroupMemberAtMixedBoundaryStaysAtGroupEnd() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("first", group: "g"),
            workspace("last", group: "g"),
            workspace("root-a"),
            workspace("root-b"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 1),
            destination: 3
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "root-a"))
    }

    @Test func groupedWorkspaceLeavesOnlyBelowNextRootRow() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("first", group: "g"),
            workspace("last", group: "g"),
            workspace("root-a"),
            workspace("root-b"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 1),
            destination: 5
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "root-b"))
    }

    @Test func belowExpandedAnchorOnlyHeaderJoinsGroup() {
        let workspaces = [workspace("anchor", group: "g"), workspace("root"), workspace("dragged")]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 2),
            destination: 1
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "root"))
    }

    @Test func workspacesApplyingGroupIntentPlacesMovedWorkspaceInsideGroup() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
            workspace("root"),
            workspace("dragged"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let moved = workspaces.applyingWorkspaceMoveIntent(
            MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "root"),
            movedWorkspaceID: "dragged",
            groups: groups
        )
        #expect(moved.map(\.id.rawValue) == ["anchor", "member", "dragged", "root"])
        #expect(moved.first(where: { $0.id == "dragged" })?.groupID == "g")
    }

    @Test func workspacesApplyingRootIntentUngroupsMovedWorkspace() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
            workspace("root"),
            workspace("dragged", group: "g"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let moved = workspaces.applyingWorkspaceMoveIntent(
            MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "root"),
            movedWorkspaceID: "dragged",
            groups: groups
        )
        #expect(moved.map(\.id.rawValue) == ["anchor", "member", "dragged", "root"])
        #expect(moved.first(where: { $0.id == "dragged" })?.groupID == nil)
    }

    @Test func externalWorkspaceAtGroupEndGapRemainsRoot() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
            workspace("root"),
            workspace("dragged"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 4),
            destination: 3
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "root"))
    }

    @Test func mixedGapBeforeFollowingHeaderStaysTopLevelForExternalWorkspace() {
        let workspaces = [
            workspace("a-anchor", group: "a"),
            workspace("a-member", group: "a"),
            workspace("b-anchor", group: "b"),
            workspace("b-member", group: "b"),
            workspace("dragged"),
        ]
        let groups = [
            group("a", anchor: "a-anchor"),
            group("b", anchor: "b-anchor"),
        ]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 6),
            destination: 3
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "b-anchor"))
    }

    @Test func listMoveIntentGapBelowCollapsedHeaderStaysTopLevel() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
            workspace("dragged"),
            workspace("tail"),
        ]
        let groups = [group("g", anchor: "anchor", collapsed: true)]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 2),
            destination: 1
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "dragged"))
    }

    @Test func listMoveIntentLandingInUngroupedRunUngroupsWorkspace() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("dragged", group: "g"),
            workspace("top"),
            workspace("bottom"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 1),
            destination: 4
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "bottom"))
    }

    @Test func listMoveIntentLandingAtVeryBottomAppendsUngroupedWorkspace() {
        let workspaces = [workspace("a"), workspace("b"), workspace("c")]
        let items = workspaces.map { MobileWorkspaceListItem.workspace($0, indented: false) }
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet(integer: 0),
            destination: 3
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: nil))
    }

    @Test func collapsedGroupEmitsNoEndOfGroupSlot() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("anchor", group: "g"),
                workspace("member", group: "g"),
                workspace("tail"),
            ],
            groups: [group("g", anchor: "anchor", collapsed: true)]
        )
        #expect(items == [
            .groupHeader(group("g", anchor: "anchor", collapsed: true), unread: .read),
            .workspace(workspace("tail"), indented: false),
        ])
    }
}
