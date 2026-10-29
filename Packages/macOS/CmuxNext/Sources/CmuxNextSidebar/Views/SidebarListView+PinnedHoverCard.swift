import AppKit

// A pinned workspace draws as an item of its section's block (`SidebarBlockRowView`), not as a list
// row, so the list's workspace lookups never saw it and its row showed no hover card (Lawrence
// 2026-10-28: "pinned rows needs hover cards too"). These find it, so the list's one card controller
// (`WorkspaceHoverCardController`) shows the card a list row shows: the same delay, contents and place.
extension SidebarListViewComponents {
    /// The workspace a hover card reads for `id`: the list's row, else the open pinned workspace a block draws.
    func hoverCardRow(_ id: WorkspaceID) -> SidebarWorkspace? {
        if let row = workspaces[id] { return row }
        // A handful of block items at most (the pins): no index to keep in step with the blocks.
        return blocks?.infos.values.lazy.compactMap(\.workspaceRow).first { $0.id == id }
    }

    /// The drawn block item (a pinned workspace's row) of open workspace `id`; nil when no block draws it.
    func blockItemView(for id: WorkspaceID) -> SidebarItemRowView? {
        for region in blockRegions {
            for view in region.itemViews.values where view.info.workspaceRow?.id == id && Self.showsCard(view) {
                return view
            }
        }
        return nil
    }

    /// The pinned workspace whose row's fill holds `point` (this view's coordinates); nil off every pinned row,
    /// and while a block edits its items (a press there only drags).
    func blockWorkspace(at point: CGPoint) -> WorkspaceID? {
        for region in blockRegions where !region.isEditing {
            for view in region.itemViews.values {
                guard let row = view.info.workspaceRow, Self.showsCard(view), !row.rowState.isPending,
                      convert(view.pill.frame, from: view).contains(point) else { continue }
                return row.id
            }
        }
        return nil
    }

    /// A block item a card may stand beside: drawn, and not a drag's hidden source or gap.
    private static func showsCard(_ view: SidebarItemRowView) -> Bool {
        !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0.01
    }
}
