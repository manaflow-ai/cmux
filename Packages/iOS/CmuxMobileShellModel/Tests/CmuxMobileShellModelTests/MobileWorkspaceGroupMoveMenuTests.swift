import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceGroupMoveMenuTests {
    private func workspace(
        _ id: String,
        group: String? = nil,
        pinned: Bool = false,
        mac: String? = nil,
        tag: String? = nil
    ) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            isPinned: pinned,
            groupID: group.map { .init(rawValue: $0) },
            terminals: []
        )
        workspace.macDeviceID = mac
        workspace.macInstanceTag = tag
        return workspace
    }

    private func group(
        _ id: String,
        anchor: String,
        collapsed: Bool = false,
        mac: String? = nil,
        tag: String? = nil
    ) -> MobileWorkspaceGroupPreview {
        var group = MobileWorkspaceGroupPreview(
            id: .init(rawValue: id),
            name: id,
            isCollapsed: collapsed,
            anchorWorkspaceID: .init(rawValue: anchor)
        )
        group.macDeviceID = mac
        group.macInstanceTag = tag
        return group
    }

    private func makeMenu(
        _ workspaces: [MobileWorkspacePreview],
        _ groups: [MobileWorkspaceGroupPreview],
        moved: String
    ) -> MobileWorkspaceGroupMoveMenu {
        MobileWorkspaceGroupMoveMenu(
            workspaces: workspaces,
            groups: groups,
            movedWorkspaceID: .init(rawValue: moved)
        )
    }

    @Test func rootWorkspaceSeesEveryGroupEnabledAndCannotRemove() {
        let menu = makeMenu(
            [
                workspace("g-anchor", group: "g"),
                workspace("g-one", group: "g"),
                workspace("h-anchor", group: "h"),
                workspace("root"),
            ],
            [group("g", anchor: "g-anchor"), group("h", anchor: "h-anchor")],
            moved: "root"
        )
        #expect(menu.entries.map(\.group.id.rawValue) == ["g", "h"])
        #expect(menu.entries.allSatisfy { $0.isEnabled && !$0.isCurrent })
        #expect(!menu.canRemoveFromGroup)
        #expect(!menu.isEmpty)
    }

    @Test func groupedWorkspaceGetsCheckedDisabledCurrentEntryAndCanRemove() {
        let menu = makeMenu(
            [
                workspace("g-anchor", group: "g"),
                workspace("g-one", group: "g"),
                workspace("h-anchor", group: "h"),
            ],
            [group("g", anchor: "g-anchor"), group("h", anchor: "h-anchor")],
            moved: "g-one"
        )
        let current = menu.entries.first { $0.group.id.rawValue == "g" }
        let other = menu.entries.first { $0.group.id.rawValue == "h" }
        #expect(current?.isCurrent == true)
        #expect(current?.isEnabled == false)
        #expect(other?.isCurrent == false)
        #expect(other?.isEnabled == true)
        #expect(menu.canRemoveFromGroup)
    }

    @Test func anchorWorkspaceGetsEmptyMenu() {
        let menu = makeMenu(
            [
                workspace("g-anchor", group: "g"),
                workspace("g-one", group: "g"),
                workspace("h-anchor", group: "h"),
            ],
            [group("g", anchor: "g-anchor"), group("h", anchor: "h-anchor")],
            moved: "g-anchor"
        )
        #expect(menu.entries.isEmpty)
        #expect(!menu.canRemoveFromGroup)
        #expect(menu.isEmpty)
    }

    @Test func unknownWorkspaceGetsEmptyMenu() {
        let menu = makeMenu(
            [workspace("g-anchor", group: "g")],
            [group("g", anchor: "g-anchor")],
            moved: "missing"
        )
        #expect(menu.isEmpty)
    }

    @Test func groupsFromAnotherMacAreExcluded() {
        let menu = makeMenu(
            [
                workspace("a-anchor", group: "a-group", mac: "mac-a", tag: "dev"),
                workspace("a-root", mac: "mac-a", tag: "dev"),
                workspace("b-anchor", group: "b-group", mac: "mac-b"),
            ],
            [
                group("a-group", anchor: "a-anchor", mac: "mac-a", tag: "dev"),
                group("b-group", anchor: "b-anchor", mac: "mac-b"),
            ],
            moved: "a-root"
        )
        #expect(menu.entries.map(\.group.id.rawValue) == ["a-group"])
    }

    @Test func emptyMacStampOnGroupMatchesUnstampedWorkspace() {
        // Aggregation stamps groups unconditionally (possibly with an empty
        // device id) but workspaces only when the owner id is non-empty.
        let menu = makeMenu(
            [
                workspace("g-anchor", group: "g"),
                workspace("root"),
            ],
            [group("g", anchor: "g-anchor", mac: "")],
            moved: "root"
        )
        #expect(menu.entries.map(\.group.id.rawValue) == ["g"])
        #expect(menu.entries.first?.isEnabled == true)
    }

    @Test func collapsedGroupIsStillATarget() {
        let menu = makeMenu(
            [
                workspace("g-anchor", group: "g"),
                workspace("root"),
            ],
            [group("g", anchor: "g-anchor", collapsed: true)],
            moved: "root"
        )
        #expect(menu.entries.first?.isEnabled == true)
    }

    @Test func workspaceWhoseGroupNoLongerExistsCannotRemove() {
        let menu = makeMenu(
            [
                workspace("orphan", group: "deleted"),
                workspace("g-anchor", group: "g"),
            ],
            [group("g", anchor: "g-anchor")],
            moved: "orphan"
        )
        #expect(!menu.canRemoveFromGroup)
        #expect(menu.entries.map(\.group.id.rawValue) == ["g"])
    }

    @Test func soleGroupMembershipStillShowsMenuThroughRemove() {
        let menu = makeMenu(
            [
                workspace("g-anchor", group: "g"),
                workspace("g-one", group: "g"),
            ],
            [group("g", anchor: "g-anchor")],
            moved: "g-one"
        )
        #expect(menu.entries.count == 1)
        #expect(menu.entries.first?.isEnabled == false)
        #expect(menu.canRemoveFromGroup)
        #expect(!menu.isEmpty)
    }
}
