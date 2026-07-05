import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceListItemTests {
    private func workspace(
        _ id: String,
        group: String? = nil,
        unread: Bool = false
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            groupID: group.map { .init(rawValue: $0) },
            hasUnread: unread,
            terminals: []
        )
    }

    private func group(
        _ id: String,
        anchor: String,
        collapsed: Bool = false,
        pinned: Bool = false,
        name: String? = nil
    ) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: .init(rawValue: id),
            name: name ?? id,
            isCollapsed: collapsed,
            isPinned: pinned,
            anchorWorkspaceID: .init(rawValue: anchor)
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
        // Anchor "a" owns group "g"; member "b" is nested. The anchor must not
        // also appear as a workspace row.
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "g"), workspace("b", group: "g")],
            groups: [group("g", anchor: "a")]
        )
        #expect(items == [
            .groupHeader(group("g", anchor: "a"), hasUnread: false),
            .workspace(workspace("b", group: "g"), indented: true),
        ])
    }

    @Test func collapsedGroupHidesMembersButKeepsHeader() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "g"), workspace("b", group: "g")],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [.groupHeader(group("g", anchor: "a", collapsed: true), hasUnread: false)])
    }

    @Test func ungroupedAndGroupedInterleaveByPosition() {
        // Mirrors the Mac sidebar: items follow `workspaces` order, the group
        // header lands at its first member's position.
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
            .groupHeader(group("g", anchor: "anchor"), hasUnread: false),
            .workspace(workspace("member", group: "g"), indented: true),
            .workspace(workspace("bottom"), indented: false),
        ])
    }

    @Test func unknownGroupIDDegradesToUngroupedRow() {
        // A workspace referencing a group that is not in `groups` (transient
        // payload skew) must still render, as an ungrouped row, not vanish.
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "missing")],
            groups: []
        )
        #expect(items == [.workspace(workspace("a", group: "missing"), indented: false)])
    }

    @Test func anchorOnlyGroupRendersHeaderWithNoMembers() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "g")],
            groups: [group("g", anchor: "a")]
        )
        #expect(items == [.groupHeader(group("g", anchor: "a"), hasUnread: false)])
    }

    // MARK: Header unread aggregation (mirrors the Mac sidebar header badge)

    @Test func collapsedGroupHeaderCarriesMemberUnread() {
        // A collapsed group hides its member rows, so the header must surface
        // their unread state; otherwise collapsing a group swallows activity.
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g"),
                workspace("b", group: "g", unread: true),
            ],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [.groupHeader(group("g", anchor: "a", collapsed: true), hasUnread: true)])
    }

    @Test func collapsedGroupHeaderCarriesAnchorUnread() {
        // The anchor never renders as its own row, so its unread state must
        // reach the header even when no other member is unread.
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g", unread: true),
                workspace("b", group: "g"),
            ],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [.groupHeader(group("g", anchor: "a", collapsed: true), hasUnread: true)])
    }

    @Test func expandedGroupHeaderReflectsOnlyTheAnchor() {
        // While expanded, member rows are visible and carry their own dots;
        // the header only represents the anchor (matching the Mac header).
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g"),
                workspace("b", group: "g", unread: true),
            ],
            groups: [group("g", anchor: "a")]
        )
        #expect(items == [
            .groupHeader(group("g", anchor: "a"), hasUnread: false),
            .workspace(workspace("b", group: "g", unread: true), indented: true),
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
            .groupHeader(group("g", anchor: "a"), hasUnread: true),
            .workspace(workspace("b", group: "g"), indented: true),
        ])
    }

    @Test func collapsedHeaderAggregatesNonContiguousMembers() {
        // A stray member separated from its group's run still feeds the
        // header's collapsed aggregate (membership is never silently dropped).
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g"),
                workspace("mid"),
                workspace("b", group: "g", unread: true),
            ],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [
            .groupHeader(group("g", anchor: "a", collapsed: true), hasUnread: true),
            .workspace(workspace("mid"), indented: false),
        ])
    }

    // MARK: Drop intent

    @Test func dropIntentReordersWithinUngroupedRegion() {
        let intent = MobileWorkspaceDropIntentResolver.intent(
            workspaces: [workspace("a"), workspace("b"), workspace("c")],
            groups: [],
            draggedWorkspaceID: "c",
            target: .beforeWorkspace("a")
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "a"))
    }

    @Test func dropIntentAppendsOntoGroupHeader() {
        let intent = MobileWorkspaceDropIntentResolver.intent(
            workspaces: [
                workspace("anchor", group: "g"),
                workspace("member", group: "g"),
                workspace("dragged"),
                workspace("tail"),
            ],
            groups: [group("g", anchor: "anchor")],
            draggedWorkspaceID: "dragged",
            target: .groupHeader("g")
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "tail"))
    }

    @Test func dropIntentMovesBetweenGroupMembers() {
        let intent = MobileWorkspaceDropIntentResolver.intent(
            workspaces: [
                workspace("anchor", group: "g"),
                workspace("first", group: "g"),
                workspace("second", group: "g"),
                workspace("dragged"),
            ],
            groups: [group("g", anchor: "anchor")],
            draggedWorkspaceID: "dragged",
            target: .beforeWorkspace("second")
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: "g", beforeWorkspaceID: "second"))
    }

    @Test func dropIntentUngroupsIntoUngroupedRegion() {
        let intent = MobileWorkspaceDropIntentResolver.intent(
            workspaces: [
                workspace("anchor", group: "g"),
                workspace("dragged", group: "g"),
                workspace("top"),
                workspace("bottom"),
            ],
            groups: [group("g", anchor: "anchor")],
            draggedWorkspaceID: "dragged",
            target: .beforeWorkspace("bottom")
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "bottom"))
    }

    @Test func dropIntentInsertsAfterTargetWorkspace() {
        let intent = MobileWorkspaceDropIntentResolver.intent(
            workspaces: [workspace("a"), workspace("b"), workspace("c")],
            groups: [],
            draggedWorkspaceID: "a",
            target: .afterWorkspace("b")
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: "c"))
    }

    @Test func dropIntentInsertsAfterLastWorkspaceAppends() {
        let intent = MobileWorkspaceDropIntentResolver.intent(
            workspaces: [workspace("a"), workspace("b"), workspace("c")],
            groups: [],
            draggedWorkspaceID: "a",
            target: .afterWorkspace("c")
        )
        #expect(intent == MobileWorkspaceMoveIntent(groupID: nil, beforeWorkspaceID: nil))
    }

    @Test func dropIntentIgnoresSelfDrop() {
        let intent = MobileWorkspaceDropIntentResolver.intent(
            workspaces: [workspace("a"), workspace("b")],
            groups: [],
            draggedWorkspaceID: "a",
            target: .beforeWorkspace("a")
        )
        #expect(intent == nil)
    }
}
