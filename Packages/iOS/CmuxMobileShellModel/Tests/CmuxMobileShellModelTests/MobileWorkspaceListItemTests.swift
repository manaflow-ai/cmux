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
        parent: String? = nil,
        name: String? = nil
    ) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: .init(rawValue: id),
            name: name ?? id,
            isCollapsed: collapsed,
            isPinned: pinned,
            parentGroupID: parent.map { .init(rawValue: $0) },
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

    @Test func expandedGroupKeepsNonContiguousMemberAtSpatialPosition() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("a", group: "g"),
                workspace("mid"),
                workspace("b", group: "g"),
            ],
            groups: [group("g", anchor: "a")]
        )

        #expect(items == [
            .groupHeader(group("g", anchor: "a"), hasUnread: false),
            .workspace(workspace("mid"), indented: false),
            .workspace(workspace("b", group: "g"), indented: true),
        ])
    }

    @Test func nestedGroupsRenderUnderExpandedParent() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("hotels-anchor", group: "hotels"),
                workspace("hotels-loose", group: "hotels"),
                workspace("marriott-anchor", group: "marriott"),
                workspace("terminal", group: "marriott"),
                workspace("outside"),
            ],
            groups: [
                group("hotels", anchor: "hotels-anchor"),
                group("marriott", anchor: "marriott-anchor", parent: "hotels"),
            ]
        )

        #expect(items == [
            .groupHeader(group("hotels", anchor: "hotels-anchor"), hasUnread: false),
            .workspace(workspace("hotels-loose", group: "hotels"), indented: true),
            .groupHeader(group("marriott", anchor: "marriott-anchor", parent: "hotels"), hasUnread: false, depth: 1),
            .workspace(workspace("terminal", group: "marriott"), indented: true, depth: 1),
            .workspace(workspace("outside"), indented: false),
        ])
    }

    @Test func collapsedParentGroupHidesDescendantGroupsAndRows() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("hotels-anchor", group: "hotels"),
                workspace("marriott-anchor", group: "marriott"),
                workspace("terminal", group: "marriott", unread: true),
                workspace("outside"),
            ],
            groups: [
                group("hotels", anchor: "hotels-anchor", collapsed: true),
                group("marriott", anchor: "marriott-anchor", parent: "hotels"),
            ]
        )

        #expect(items == [
            .groupHeader(group("hotels", anchor: "hotels-anchor", collapsed: true), hasUnread: true),
            .workspace(workspace("outside"), indented: false),
        ])
    }

    @Test func collapsedChildGroupRemainsVisibleUnderExpandedParent() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [
                workspace("hotels-anchor", group: "hotels"),
                workspace("marriott-anchor", group: "marriott"),
                workspace("terminal", group: "marriott", unread: true),
            ],
            groups: [
                group("hotels", anchor: "hotels-anchor"),
                group("marriott", anchor: "marriott-anchor", collapsed: true, parent: "hotels"),
            ]
        )

        #expect(items == [
            .groupHeader(group("hotels", anchor: "hotels-anchor"), hasUnread: false),
            .groupHeader(
                group("marriott", anchor: "marriott-anchor", collapsed: true, parent: "hotels"),
                hasUnread: true,
                depth: 1
            ),
        ])
    }
}
