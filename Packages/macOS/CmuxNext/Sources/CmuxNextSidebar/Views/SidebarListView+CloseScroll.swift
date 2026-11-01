import AppKit
import CmuxNextDesign
/// Sidebar scroll after a close, create or selection change
/// (plans/cmux-next/close-focus.md): `ListViewport.settle` decides the
/// offset; this file only reads geometry and applies it.
extension SidebarListViewComponents {
    /// Applies `layout` keeping what the user sees (the anchor stays put,
    /// rows and offset shift together so nothing jumps), then reveals the
    /// selection (`selectionReveal`) when it changed, or its row when it moved
    /// or was pushed out of view, by anyone (sidebar-focused-visible: the
    /// focused row is always in view); the reveal animates with `Motion`
    /// (instant under Reduce Motion, and to a new row, Cmd-N's, cx-evo3q) and
    /// is the only scroll this change makes.
    func applyKeepingViewport(_ layout: SidebarLayout, animated: Bool) {
        let active = selectionRevealKey
        let previousActive = revealedActive
        revealedActive = active
        // Read on every reload, so a user's move is used by the structural set that shows it, and only by that one.
        let userMoved = model.takeUserMove()
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
            if let extent = selectionReveal(in: layout, height: height) {
                scrollClip(to: after.reveal(extent, from: clip.bounds.minY, padding: SidebarLayout.revealPadding), animated: false)
            }
            return
        }
        let offset = clip.bounds.minY
        let anchored = after.anchored(from: before, offset: offset)
        let delta = anchored - offset
        // Where the reveal ends, decided before anything moves (`settle` reads the layouts and this offset only).
        let target = after.settle(from: before, offset: offset, focused: previousActive, newFocus: active,
                                  padding: SidebarLayout.revealPadding, userMoved: userMoved,
                                  extent: selectionReveal(in: layout, height: height))
        let toNewRow = active.map { before.item($0) == nil && after.item($0) != nil } ?? false
        // Cmd-N (Lawrence 2026-10-28, sidebar-burst-motion.md): a new row the reveal shows where the list already is
        // (the list at its top, the row inserted there) needs no scroll at all. The anchor shift would move the rows
        // and the offset down together and the reveal would jump back in one frame, so the rows below would stand in
        // their new slots at once and the new row would grow from nothing in a gap already open: an empty slot. Kept
        // at the offset instead, the rows below make room by the new row motion while the row opens above them. A
        // reveal that does scroll to a new row (the list scrolled away) jumps there, and the row is in its slot,
        // whole, in that frame (``apply(_:animated:newRowsInPlace:)``).
        let keepsOffset = toNewRow && abs(target - offset) <= 0.25
        if abs(delta) > 0.25, !keepsOffset {
            RowMotion.shift(self, by: delta) // closing rows too; nothing draws until the offset moves with them
            Motion.withoutAnimation {
                // Rows and the offset move together: no visible change yet.
                if frame.height < after.content { setFrameSize(NSSize(width: frame.width, height: after.content)) }
                decorations.shift(by: delta)
                groupLineViews.shift(by: delta)
                chatHistory.shift(by: delta)
                // Rows are realized by `apply` from the new layout, not from
                // the old one while the offset moves.
                isShiftingViewport = true
                scrollClip(to: anchored, animated: false)
                isShiftingViewport = false
            }
        }
        apply(layout, animated: animated, newRowsInPlace: toNewRow && !keepsOffset && abs(target - clip.bounds.minY) > 0.25)
        if abs(target - clip.bounds.minY) > 0.25 { scrollClip(to: target, animated: animated && !toNewRow) }
    }

    /// The identity a reveal tracks for the selection: its workspace, group or
    /// item (a top item the list draws in a block too). Every entrypoint that
    /// selects (Cmd-1…9, Cmd-Ctrl-[ / ], the palette, the CLI, a click) changes
    /// `model.selectedItem`, so all of them reveal through this one key.
    var selectionRevealKey: SidebarRowKey? {
        switch model.selectedItem {
        case let .workspace(id)?: .workspace(id)
        case let .group(id)?: .group(id)
        case let .topItem(id)?: .item(id.rawValue)
        case nil: nil
        }
    }

    /// What revealing the selection shows in `layout` (a viewport `height`
    /// tall): the row that stands for it, or its item inside a block row, with
    /// the context `SidebarLayout.revealExtent` adds (the header above it, the
    /// list's top when only top items draw before it: Home, the App Store, the
    /// first workspace under them, as `SidebarItemOrder.revealsTop`, #22253).
    /// A top item the band above the list draws reveals the list's top alone.
    /// Read from the drawn rows only: never the whole item order (a space
    /// switch with 500 workspaces). Nil when the list shows nothing for it.
    func selectionReveal(in layout: SidebarLayout, height: CGFloat) -> ListViewport<SidebarRowKey>.Item? {
        guard let id = selectionRevealKey else { return nil }
        if let extent = listedReveal(id, in: layout, height: height) { return extent }
        // A top item the band above the list draws: the list shows its top (#22253).
        if case .topItem? = model.selectedItem { return .init(id: id, start: 0, length: 0) }
        return nil
    }

    /// `selectionReveal`'s row or block item, as the list draws it.
    private func listedReveal(_ id: SidebarRowKey, in layout: SidebarLayout, height: CGFloat) -> ListViewport<SidebarRowKey>.Item? {
        if let key = layout.selectedRowKey(for: model.selectedItem, in: model.sections) {
            return layout.revealExtent(id: id, row: key, height: height)
        }
        guard case let .topItem(item)? = model.selectedItem, let blocks,
              let section = blocks.sections.first(where: { $0.value.items.contains { $0.id == item } })?.key,
              let row = layout.row(for: .block(section)) else { return nil }
        // The block's region lays out at the row's origin (`SidebarBlockRowView`).
        let frame = blockContent(section, includeGap: false).flatMap { content in
            SidebarRegionView.layout(of: content, width: bounds.width).rows.first { $0.kind.itemID == item }?.frame
        }
        return layout.revealExtent(id: id, row: .block(section), span: frame.map { (row.y + $0.minY, $0.height) }, height: height)
    }
    func scrollClip(to y: CGFloat, animated: Bool) {
        enclosingScrollView?.scrollContent(toY: y, animated: animated) { [weak self] in self?.realizeVisibleRows() }
    }
}

private extension SidebarRegionRow.Kind {
    /// The item this region row draws, if any.
    var itemID: LayoutItemID? {
        switch self {
        case let .item(id, _), let .tile(id, _), let .chip(id, _): id
        case .header, .app: nil
        }
    }
}
