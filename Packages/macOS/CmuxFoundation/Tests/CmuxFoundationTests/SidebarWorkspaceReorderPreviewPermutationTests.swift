import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct SidebarWorkspaceReorderPreviewPermutationTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()
    private let groupAnchor = UUID()
    private let member1 = UUID()
    private let member2 = UUID()
    private let groupId = UUID()

    private func row(_ id: UUID, group: UUID? = nil, header: Bool = false) -> SidebarWorkspaceReorderPreviewRow {
        SidebarWorkspaceReorderPreviewRow(workspaceId: id, groupId: group, isGroupHeader: header)
    }

    /// a b c d, drag a below c → b c a d
    @Test func movesWorkspaceBelowTarget() throws {
        let rows = [row(a), row(b), row(c), row(d)]
        let preview = try #require(SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: a,
            indicator: SidebarDropIndicator(tabId: c, edge: .bottom),
            scope: .raw
        ))
        #expect(preview.order == [1, 2, 0, 3])
        #expect(preview.draggedBlock == [0])
        #expect(preview.destinationGroupId == nil)
    }

    /// a b c d, drag d above b → a d b c
    @Test func movesWorkspaceAboveTarget() throws {
        let rows = [row(a), row(b), row(c), row(d)]
        let preview = try #require(SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: d,
            indicator: SidebarDropIndicator(tabId: b, edge: .top),
            scope: .raw
        ))
        #expect(preview.order == [0, 3, 1, 2])
    }

    /// nil tabId inserts at the end of the list.
    @Test func nilTargetAppendsAtEnd() throws {
        let rows = [row(a), row(b), row(c)]
        let preview = try #require(SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: a,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
            scope: .raw
        ))
        #expect(preview.order == [1, 2, 0])
    }

    /// An indicator that points at the dragged row itself keeps the order.
    @Test func selfTargetIsIdentity() throws {
        let rows = [row(a), row(b), row(c)]
        let preview = try #require(SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: b,
            indicator: SidebarDropIndicator(tabId: b, edge: .top),
            scope: .raw
        ))
        #expect(preview.order == [0, 1, 2])
    }

    /// Dragging a group anchor picks up the header and its contiguous member
    /// rows as one block.
    @Test func anchorDragMovesWholeBlock() throws {
        let rows = [
            row(a),
            row(groupAnchor, group: groupId, header: true),
            row(member1, group: groupId),
            row(member2, group: groupId),
            row(b),
        ]
        let preview = try #require(SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: groupAnchor,
            indicator: SidebarDropIndicator(tabId: b, edge: .bottom),
            scope: .topLevel
        ))
        #expect(preview.draggedBlock == [1, 2, 3])
        #expect(preview.order == [0, 4, 1, 2, 3])
    }

    /// Top-level scope: a bottom edge against a group header lands below the
    /// whole expanded group, not between the header and its first member.
    @Test func bottomOfHeaderSkipsGroupMembers() throws {
        let rows = [
            row(a),
            row(groupAnchor, group: groupId, header: true),
            row(member1, group: groupId),
            row(member2, group: groupId),
            row(b),
        ]
        let preview = try #require(SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: a,
            indicator: SidebarDropIndicator(tabId: groupAnchor, edge: .bottom),
            scope: .topLevel
        ))
        #expect(preview.order == [1, 2, 3, 0, 4])
        #expect(preview.destinationGroupId == nil)
    }

    /// Group scope: inserting below a member row joins the group and reports
    /// the destination group for the indent preview.
    @Test func groupScopeInsertsAmongMembers() throws {
        let rows = [
            row(a),
            row(groupAnchor, group: groupId, header: true),
            row(member1, group: groupId),
            row(member2, group: groupId),
            row(b),
        ]
        let preview = try #require(SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: a,
            indicator: SidebarDropIndicator(tabId: member1, edge: .bottom),
            scope: .group(groupId)
        ))
        #expect(preview.order == [1, 2, 0, 3, 4])
        #expect(preview.destinationGroupId == groupId)
    }

    /// Group scope with the anchor as target (slot directly below a header,
    /// e.g. a collapsed group) inserts right after the header row.
    @Test func groupScopeAnchorTargetInsertsBelowHeader() throws {
        let rows = [
            row(a),
            row(groupAnchor, group: groupId, header: true),
            row(b),
        ]
        let preview = try #require(SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: a,
            indicator: SidebarDropIndicator(tabId: groupAnchor, edge: .bottom),
            scope: .group(groupId)
        ))
        #expect(preview.order == [1, 0, 2])
        #expect(preview.destinationGroupId == groupId)
    }

    /// Unknown indicator target refuses (caller keeps the last preview).
    @Test func unknownTargetReturnsNil() {
        let rows = [row(a), row(b)]
        let preview = SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: a,
            indicator: SidebarDropIndicator(tabId: UUID(), edge: .top),
            scope: .raw
        )
        #expect(preview == nil)
    }

    /// Dragged id missing from the rows refuses.
    @Test func missingDraggedRowReturnsNil() {
        let rows = [row(a), row(b)]
        let preview = SidebarWorkspaceReorderPreviewPermutation().previewOrder(
            rows: rows,
            draggedWorkspaceId: UUID(),
            indicator: SidebarDropIndicator(tabId: a, edge: .top),
            scope: .raw
        )
        #expect(preview == nil)
    }
}
