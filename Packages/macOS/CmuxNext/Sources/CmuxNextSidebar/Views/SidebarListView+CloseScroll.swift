import AppKit
import CmuxNextDesign

/// Sidebar scroll after a close, create or selection change
/// (plans/cmux-next/close-focus.md): `ListViewport.settle` decides the
/// offset; this file only reads geometry and applies it.
extension SidebarListView {
    /// Space kept around a revealed active row.
    static let revealPadding: CGFloat = 8

    func viewport(of layout: SidebarLayout) -> ListViewport<SidebarRowKey>? {
        guard let clip = enclosingScrollView?.contentView else { return nil }
        let height = clip.bounds.height
        return ListViewport(items: layout.rows.map { .init(id: $0.key, start: $0.y, length: $0.height) },
                            viewport: height, content: max(layout.totalHeight, height))
    }

    var scrollOffset: CGFloat { enclosingScrollView?.contentView.bounds.minY ?? 0 }

    /// Applies `layout` keeping what the user sees (the anchor stays put,
    /// rows and offset shift together so nothing jumps), then reveals the
    /// active workspace when it changed or was fully visible; the reveal
    /// animates with `Motion` (instant under Reduce Motion) and is the only
    /// scroll this change makes.
    func applyKeepingViewport(_ layout: SidebarLayout, animated: Bool) {
        let active = model.activeWorkspaceID.map { SidebarRowKey.workspace($0) }
        let previousActive = revealedActive
        revealedActive = active
        guard drag == nil, external == nil, let clip = enclosingScrollView?.contentView,
              let before = viewport(of: displayed), let after = viewport(of: layout) else {
            apply(layout, animated: animated)
            return
        }
        if displayed.rows.isEmpty || clip.bounds.height <= 0 {
            // First rows: show the active workspace, no animation. Without a
            // viewport yet (init), the next reload reveals it.
            apply(layout, animated: false)
            guard clip.bounds.height > 0 else {
                revealedActive = nil
                return
            }
            if let active, let row = after.item(active) {
                scrollClip(to: after.reveal(row, from: clip.bounds.minY, padding: Self.revealPadding), animated: false)
            }
            return
        }
        let offset = clip.bounds.minY
        let anchored = after.anchored(from: before, offset: offset, focused: previousActive)
        let delta = anchored - offset
        if abs(delta) > 0.25 {
            Motion.withoutAnimation {
                // Rows and the offset move together: no visible change yet.
                let height = max(frame.height, after.content)
                if frame.height < height { setFrameSize(NSSize(width: frame.width, height: height)) }
                for view in rowViews.values { view.frame.origin.y += delta }
                decorations.shift(by: delta)
                // Rows are realized by `apply` from the new layout, not from
                // the old one while the offset moves.
                isShiftingViewport = true
                scrollClip(to: anchored, animated: false)
                isShiftingViewport = false
            }
        }
        apply(layout, animated: animated)
        let target = after.settle(from: before, offset: offset, focused: previousActive, newFocus: active,
                                  padding: Self.revealPadding)
        if abs(target - clip.bounds.minY) > 0.25 { scrollClip(to: target, animated: animated) }
    }

    func scrollClip(to y: CGFloat, animated: Bool) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let origin = NSPoint(x: clip.bounds.minX, y: y)
        if animated, Motion.animatesMovement {
            Motion.animate(.move, { clip.animator().setBoundsOrigin(origin) }, completion: { [weak self] in
                scroll.reflectScrolledClipView(clip)
                self?.realizeVisibleRows()
            })
        } else {
            clip.setBoundsOrigin(origin)
            scroll.reflectScrolledClipView(clip)
        }
        realizeVisibleRows()
    }
}
