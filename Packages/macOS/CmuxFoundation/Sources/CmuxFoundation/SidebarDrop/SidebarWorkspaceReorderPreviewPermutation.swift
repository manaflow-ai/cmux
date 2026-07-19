public import Foundation

/// One visible sidebar row as seen by the live-reorder preview.
public struct SidebarWorkspaceReorderPreviewRow: Equatable, Sendable {
    public let workspaceId: UUID
    public let groupId: UUID?
    public let isGroupHeader: Bool

    public init(workspaceId: UUID, groupId: UUID?, isGroupHeader: Bool) {
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.isGroupHeader = isGroupHeader
    }
}

/// The row order the sidebar should show while a drag hovers a resolved plan,
/// expressed as source indices into the input rows.
public struct SidebarWorkspaceReorderPreviewOrder: Equatable, Sendable {
    /// Indices into the input rows, in the order the preview should display.
    public let order: [Int]

    /// Indices into the input rows forming the dragged block (header first
    /// for group drags, single element for workspace drags).
    public let draggedBlock: [Int]

    /// The group the dragged workspace would join when dropped here, `nil`
    /// for a top-level slot. Drives the floating row's indent preview.
    public let destinationGroupId: UUID?
}

/// Maps a resolved drop plan's indicator onto a concrete visible row order so
/// the table can animate rows apart while the drag is still in flight. The
/// commit stays plan-driven; this only decides what the preview shows, and it
/// is derived from the same indicator the resolver would render, so the
/// settled preview and the committed order agree.
public struct SidebarWorkspaceReorderPreviewPermutation: Sendable {
    public init() {}

    /// Resolves the preview order for a plan, or `nil` when the indicator
    /// cannot be mapped onto the visible rows (the caller should keep the
    /// last valid preview).
    public func previewOrder(
        rows: [SidebarWorkspaceReorderPreviewRow],
        draggedWorkspaceId: UUID,
        indicator: SidebarDropIndicator,
        scope: SidebarWorkspaceReorderDropIndicatorScope
    ) -> SidebarWorkspaceReorderPreviewOrder? {
        guard let block = draggedBlockIndices(rows: rows, draggedWorkspaceId: draggedWorkspaceId),
              !block.isEmpty else {
            return nil
        }
        // An indicator pointing at the dragged block itself is a no-op slot.
        if let tabId = indicator.tabId, block.contains(where: { rows[$0].workspaceId == tabId }) {
            return SidebarWorkspaceReorderPreviewOrder(
                order: Array(rows.indices),
                draggedBlock: block,
                destinationGroupId: destinationGroupId(scope: scope)
            )
        }

        let blockSet = Set(block)
        let remaining = rows.indices.filter { !blockSet.contains($0) }
        guard let insertionOffset = insertionOffset(
            rows: rows,
            remaining: remaining,
            indicator: indicator,
            scope: scope
        ) else {
            return nil
        }

        var order: [Int] = []
        order.reserveCapacity(rows.count)
        order.append(contentsOf: remaining.prefix(insertionOffset))
        order.append(contentsOf: block)
        order.append(contentsOf: remaining.dropFirst(insertionOffset))
        return SidebarWorkspaceReorderPreviewOrder(
            order: order,
            draggedBlock: block,
            destinationGroupId: destinationGroupId(scope: scope)
        )
    }

    /// The dragged rows as one unit: a workspace row alone, or a group header
    /// plus its contiguous member rows when the dragged id is a group anchor.
    private func draggedBlockIndices(
        rows: [SidebarWorkspaceReorderPreviewRow],
        draggedWorkspaceId: UUID
    ) -> [Int]? {
        if let headerIndex = rows.firstIndex(where: { $0.isGroupHeader && $0.workspaceId == draggedWorkspaceId }) {
            let groupId = rows[headerIndex].groupId
            var block = [headerIndex]
            var next = headerIndex + 1
            while next < rows.count, !rows[next].isGroupHeader, rows[next].groupId == groupId, groupId != nil {
                block.append(next)
                next += 1
            }
            return block
        }
        guard let rowIndex = rows.firstIndex(where: { !$0.isGroupHeader && $0.workspaceId == draggedWorkspaceId }) else {
            return nil
        }
        return [rowIndex]
    }

    /// Where in the remaining (block-removed) rows the block re-inserts.
    private func insertionOffset(
        rows: [SidebarWorkspaceReorderPreviewRow],
        remaining: [Int],
        indicator: SidebarDropIndicator,
        scope: SidebarWorkspaceReorderDropIndicatorScope
    ) -> Int? {
        guard let tabId = indicator.tabId else {
            return remaining.count
        }
        if case .group(let groupId) = scope {
            // Group scope: the indicator names a member row (or the anchor
            // when the slot is directly below a header). Insert against that
            // row's edge inside the group span.
            if let memberOffset = remaining.firstIndex(where: { index in
                let row = rows[index]
                return !row.isGroupHeader && row.groupId == groupId && row.workspaceId == tabId
            }) {
                return indicator.edge == .top ? memberOffset : memberOffset + 1
            }
            if let headerOffset = remaining.firstIndex(where: { index in
                let row = rows[index]
                return row.isGroupHeader && row.groupId == groupId
            }) {
                return headerOffset + 1
            }
            return nil
        }
        // Top-level/raw scope: the indicator names a top-level row. When that
        // row is a group header (anchor id), a bottom edge means below the
        // whole group block, not between the header and its first member.
        guard let targetOffset = remaining.firstIndex(where: { rows[$0].workspaceId == tabId }) else {
            return nil
        }
        if indicator.edge == .top {
            return targetOffset
        }
        let targetRow = rows[remaining[targetOffset]]
        guard targetRow.isGroupHeader, let groupId = targetRow.groupId else {
            return targetOffset + 1
        }
        var offset = targetOffset + 1
        while offset < remaining.count {
            let row = rows[remaining[offset]]
            if row.isGroupHeader || row.groupId != groupId { break }
            offset += 1
        }
        return offset
    }

    private func destinationGroupId(
        scope: SidebarWorkspaceReorderDropIndicatorScope
    ) -> UUID? {
        guard case .group(let groupId) = scope else { return nil }
        return groupId
    }
}
