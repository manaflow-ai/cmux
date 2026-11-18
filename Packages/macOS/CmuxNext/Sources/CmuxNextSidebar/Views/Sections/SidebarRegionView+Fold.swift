import AppKit

extension SidebarRegionView {
    /// `info` drawn active when `id` is the selected item, and as part of the multi-selection when its workspace is.
    func activeInfo(_ info: SidebarItemInfo, _ id: LayoutItemID) -> SidebarItemInfo {
        var info = info
        info.isActive = id == activeItem
        info.isSecondarySelected = !info.isActive && info.workspace.map(selectedWorkspaces.contains) == true
        return info
    }
}

/// A list block's section folding on the move spring (Leo 2026-11-08: "a bit of a flicker on that, like individual top
/// group"). Before, a close took the section's items away in the first frame, so its slot showed the header over empty
/// space for the whole spring, and an open drew every item at once, at full height, over the rows below until they moved
/// down. Now the block row clips to its frame while it springs: an open's items show as the slot opens down over them,
/// and a close's items stay where they are and go under the closing slot, as a group's members do
/// (`SidebarListView.clipFold`).
@MainActor final class SidebarRegionFoldMove {
    /// The shown content's folded sections changed: the next animated apply is a fold.
    var folds = false
    /// Item views a close left in place under the closing slot, removed when the move ends.
    var closing: [SidebarItemRowView] = []
    private var move = 0
    /// The block row this fold clips (one that clipped already, an opening row's, is left as it is).
    private weak var clipped: SidebarBlockRowView?

    /// An animated relayout of `region` begins; a fold clips its block row. Returns the move, for `end`.
    func begin(in region: SidebarRegionView) -> Int {
        move &+= 1
        if folds, let block = region.superview as? SidebarBlockRowView, !block.clipsToBounds {
            block.clipsToBounds = true
            clipped = block
        }
        return move
    }

    /// The move ended (its spring settled, or it snapped): unless a later one runs, the closed items go and the block row
    /// draws as it did before the fold.
    func end(_ ended: Int) {
        guard ended == move else { return }
        closing.forEach { $0.removeFromSuperview() }
        closing = []
        clipped?.clipsToBounds = false
        clipped = nil
    }
}
