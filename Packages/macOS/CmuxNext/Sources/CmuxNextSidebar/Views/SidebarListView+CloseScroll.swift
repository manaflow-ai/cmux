import AppKit
import CmuxNextDesign
/// Sidebar scroll after a close, create or selection change
/// (plans/cmux-next/close-focus.md): `ListViewport.settle` decides the
/// offset; this file only reads geometry and applies it.
extension SidebarListViewComponents {
    /// Applies `layout` keeping what the user sees (the anchor stays put,
    /// rows and offset shift together so nothing jumps), then reveals the
    /// active workspace when it changed, moved, or was pushed out of view, by
    /// anyone (sidebar-focused-visible: the focused row is always in view); the reveal
    /// animates with `Motion` (instant under Reduce Motion, and to a new row,
    /// Cmd-N's, cx-evo3q) and is the only scroll this change makes.
    func applyKeepingViewport(_ layout: SidebarLayout, animated: Bool) {
        let active = model.activeWorkspaceID.map { SidebarRowKey.workspace($0) }
        let previousActive = revealedActive
        revealedActive = active
        // Read on every reload, so a user's move is used by the structural set that shows it, and only by that one.
        let userMoved = model.takeUserMove()
        let revealsTop = takeTopReveal()
        guard drag == nil, external == nil, let clip = enclosingScrollView?.contentView,
              case let height = clip.bounds.height, height > 0 else {
            // No viewport yet (init): the first reload with one reveals.
            if (enclosingScrollView?.contentView.bounds.height ?? 0) <= 0 { revealedActive = nil }
            apply(layout, animated: animated)
            return
        }
        let before = displayed.viewport(height: height), after = layout.viewport(height: height)
        if displayed.rows.isEmpty {
            // First rows: show the active workspace, no animation.
            apply(layout, animated: false)
            if let active, let row = after.item(active) {
                scrollClip(to: after.reveal(row, from: clip.bounds.minY, padding: SidebarLayout.revealPadding), animated: false)
            }
            return
        }
        let offset = clip.bounds.minY
        let anchored = after.anchored(from: before, offset: offset)
        let delta = anchored - offset
        if abs(delta) > 0.25 {
            RowMotion.shift(self, by: delta) // closing rows too; nothing draws until the offset moves with them
            Motion.withoutAnimation {
                // Rows and the offset move together: no visible change yet.
                if frame.height < after.content { setFrameSize(NSSize(width: frame.width, height: after.content)) }
                decorations.shift(by: delta)
                groupLineViews.shift(by: delta)
                // Rows are realized by `apply` from the new layout, not from
                // the old one while the offset moves.
                isShiftingViewport = true
                scrollClip(to: anchored, animated: false)
                isShiftingViewport = false
            }
        }
        apply(layout, animated: animated)
        let target = after.settle(from: before, offset: offset, focused: previousActive, newFocus: active,
                                  padding: SidebarLayout.revealPadding, userMoved: userMoved)
        if revealsTop { scrollToTop(); return }
        if abs(target - clip.bounds.minY) > 0.25 { scrollClip(to: target, animated: animated && active.map { before.item($0) == nil } != true) }
    }
    func scrollClip(to y: CGFloat, animated: Bool) {
        enclosingScrollView?.scrollContent(toY: y, animated: animated) { [weak self] in self?.realizeVisibleRows() }
    }
}
