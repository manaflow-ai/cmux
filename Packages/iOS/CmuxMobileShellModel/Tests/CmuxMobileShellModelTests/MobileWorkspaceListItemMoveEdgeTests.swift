import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceListItemMoveEdgeTests {
    private func workspace(_ id: String, group: String? = nil) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            groupID: group.map { .init(rawValue: $0) },
            terminals: []
        )
    }

    private func group(_ id: String, anchor: String) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: .init(rawValue: id),
            name: id,
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceID: .init(rawValue: anchor)
        )
    }

    @Test func groupHeaderNoOpMoveIsRejected() {
        let workspaces = [workspace("anchor", group: "g"), workspace("member", group: "g")]
        let groups = [group("g", anchor: "anchor")]
        let intent = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups).moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 0),
            destination: 2
        )
        #expect(intent == nil)
    }

    @Test func groupHeaderMovesAsOneBlock() throws {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
            workspace("tail"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let intent = try #require(items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 0),
            destination: 4
        ))
        #expect(intent == MobileWorkspaceMoveIntent(
            groupID: nil,
            beforeWorkspaceID: nil,
            movesGroup: true
        ))
        let moved = workspaces.applyingWorkspaceMoveIntent(
            intent,
            movedWorkspaceID: "anchor",
            groups: groups
        )
        #expect(moved.map(\.id) == ["tail", "anchor", "member"])
        #expect(moved.suffix(2).allSatisfy { $0.groupID == "g" })
    }

    @Test func workspaceNoOpMoveIsRejected() {
        let workspaces = [workspace("a"), workspace("b"), workspace("c")]
        let items = workspaces.map { MobileWorkspaceListItem.workspace($0, indented: false) }
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: [],
            sourceOffsets: IndexSet(integer: 1),
            destination: 2
        )
        #expect(intent == nil)
    }

    @Test func identityDropAtGroupBoundaryIsRejected() {
        let workspaces = [
            workspace("anchor", group: "g"),
            workspace("member", group: "g"),
            workspace("dragged"),
        ]
        let groups = [group("g", anchor: "anchor")]
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        // [header, member, footer, dragged]: returning dragged to its gap is a no-op.
        let intent = items.moveIntent(
            workspaces: workspaces,
            groups: groups,
            sourceOffsets: IndexSet(integer: 3),
            destination: 4
        )
        #expect(intent == nil)
    }

    @Test func groupEndSlotCannotBeDragged() {
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
            sourceOffsets: IndexSet(integer: 2),
            destination: 0
        )
        #expect(intent == nil)
    }
}
