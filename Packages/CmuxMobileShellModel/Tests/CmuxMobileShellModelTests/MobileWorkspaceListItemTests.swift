import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceListItemTests {
    private func workspace(
        _ id: String,
        group: String? = nil
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            groupID: group.map { .init(rawValue: $0) },
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
            .groupHeader(group("g", anchor: "a")),
            .workspace(workspace("b", group: "g"), indented: true),
        ])
    }

    @Test func collapsedGroupHidesMembersButKeepsHeader() {
        let items = MobileWorkspaceListItem.items(
            workspaces: [workspace("a", group: "g"), workspace("b", group: "g")],
            groups: [group("g", anchor: "a", collapsed: true)]
        )
        #expect(items == [.groupHeader(group("g", anchor: "a", collapsed: true))])
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
            .groupHeader(group("g", anchor: "anchor")),
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
        #expect(items == [.groupHeader(group("g", anchor: "a"))])
    }
}
