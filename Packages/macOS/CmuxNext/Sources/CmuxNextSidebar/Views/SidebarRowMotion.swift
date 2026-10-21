import AppKit
import CmuxNextDesign

/// The rows one `SidebarListView.apply` animates, all on one spring
/// (cx-bqm6): like a browser's vertical tabs, existing rows move, new rows
/// open their slot and removed rows close theirs, so no row overlaps another
/// or waits for it. Group lines run in the same block, so a line ends at its
/// group's last row in every frame (cx-ai79).
@MainActor
struct RowMotion {
    var targets: [(SidebarRowView, NSRect)]
    var appearing: [(SidebarRowView, NSRect)]
    var leaving: [(SidebarRowView, NSRect)]
    var lines: (changes: () -> Void, leaving: [NSView])

    func run(in list: SidebarListView, from old: SidebarLayout, to layout: SidebarLayout, animated: Bool) {
        let moves = {
            for (view, target) in targets {
                view.animator().frame = target
                view.animator().alphaValue = 1
            }
        }
        guard animated else {
            Motion.withoutAnimation {
                moves()
                lines.changes()
            }
            leaving.forEach { Self.closed($0.0, in: list) }
            lines.leaving.forEach { $0.removeFromSuperview() }
            return
        }
        guard Motion.sidebar.animatesMovement else {
            // Reduce Motion: rows take their places in one step, with no crossfade standing in
            // for the motion (DESIGN P6): no movement, and nothing a person must wait out.
            Motion.withoutAnimation {
                moves()
                lines.changes()
                for (view, target) in appearing {
                    view.frame = target
                    view.alphaValue = 1
                    view.clipsToBounds = false
                }
            }
            leaving.forEach { Self.closed($0.0, in: list) }
            lines.leaving.forEach { $0.removeFromSuperview() }
            return
        }
        passOver(in: list, from: old, to: layout)
        for (view, end) in leaving { view.closingEnd = end }
        let opens = appearing.map(\.0.opens)
        Motion.sidebar.animate(.move, in: list, {
            moves()
            lines.changes()
            for (view, target) in appearing {
                view.animator().frame = target
                view.animator().alphaValue = 1
            }
            for (view, end) in leaving {
                view.animator().alphaValue = 0
                view.animator().frame = end
            }
        }, settleAtSleep: Self.settle(list), completion: { [weak list, appearing, opens, leaving, leavingLines = lines.leaving] in
            leavingLines.forEach { $0.removeFromSuperview() }
            guard let list else { return }
            // A row reopened since keeps clipping until its own open ends.
            for ((view, _), open) in zip(appearing, opens) where view.opens == open { view.clipsToBounds = false }
            for (view, _) in leaving where !list.rowViews.values.contains(where: { $0 === view }) { Self.closed(view, in: list) }
            list.pruneOffscreen()
        })
    }

    /// Moves every row by `dy` at once, with the scroll offset (the anchor step of
    /// `SidebarListView.applyKeepingViewport`). A row still closing its slot from an earlier
    /// change moves too, and its close re-targets to its shifted end, so it keeps closing in
    /// place beside its neighbors instead of jumping by `dy` against them (cx-y2uf5).
    static func shift(_ list: SidebarListView, by dy: CGFloat) {
        let closing = list.subviews.compactMap { $0 as? SidebarRowView }.filter { $0.closingEnd != nil && !$0.isHidden }
        Motion.withoutAnimation {
            for view in list.rowViews.values { view.frame.origin.y += dy }
            for view in closing {
                view.frame.origin.y += dy
                view.closingEnd?.origin.y += dy
            }
        }
        guard !closing.isEmpty else { return }
        // The close's own completion (`run`) still recycles each row.
        Motion.sidebar.animate(.move, in: list, {
            for view in closing {
                guard let end = view.closingEnd else { continue }
                view.animator().alphaValue = 0
                view.animator().frame = end
            }
        })
    }

    /// A row whose close ended (or never animated) goes back to the pool.
    private static func closed(_ view: SidebarRowView, in list: SidebarListView) {
        view.closingEnd = nil
        list.recycle(view)
    }

    /// Places a row that scrolled into view. One still opening (the viewport
    /// held still for an insert above it, then scrolled to it) opens from zero
    /// height at its slot instead of showing whole over the rows still making
    /// room (cx-ai79).
    static func place(_ view: SidebarRowView, at target: NSRect, opening: Bool, hidden: Bool, in list: SidebarListView) {
        guard opening, !hidden, Motion.sidebar.animatesMovement else {
            view.frame = target
            view.alphaValue = hidden ? 0 : 1
            return
        }
        Motion.withoutAnimation {
            view.frame = NSRect(x: target.minX, y: target.minY, width: target.width, height: 0)
            view.alphaValue = 0
            view.clipsToBounds = true
        }
        view.opens += 1
        let open = view.opens
        Motion.sidebar.animate(.move, in: list, {
            view.animator().frame = target
            view.animator().alphaValue = 1
        }, settleAtSleep: Self.settle(list), completion: { [view] in
            if view.opens == open { view.clipsToBounds = false }
        })
    }

    /// When the display sleeps mid-move (no frame draws, so the move never ends), the rows
    /// take the places the list holds then, without motion: a reload, never the targets this
    /// move captured, which a newer change may have replaced. Rows still leaving go in the
    /// move's completion, which runs right after.
    private static func settle(_ list: SidebarListView) -> @MainActor () -> Void {
        { [weak list] in list?.reload(animated: false) }
    }

    /// A moved selected row (with its workspace's tab rows) passes over the
    /// rows it trades places with: it draws above them, and each row it
    /// crosses hides at once and fades back in once the move has nearly
    /// settled, so a translucent selection fill never shows a title through
    /// it (cx-bqm6, cx-ai79).
    private func passOver(in list: SidebarListView, from old: SidebarLayout, to layout: SidebarLayout) {
        // A dragged row is hidden under its lifted card, which already draws
        // above the list: no row passes under it, so none hides (cx-ikxz).
        // A row still opening (listed, then placed: New Workspace in New Group) draws nothing yet
        // to pass over with: the rows it crosses stay as they are.
        guard let key = list.selectedRowKey, !list.suppressed.contains(key), !appearing.contains(where: { $0.0.key == key }),
              let before = old.row(for: key)?.y, let after = layout.row(for: key)?.y, before != after else { return }
        let block = Self.block(of: key)
        let passed = targets.map(\.0).filter { view in
            guard !block(view.key), let was = old.row(for: view.key)?.y, let now = layout.row(for: view.key)?.y else { return false }
            return (was < before) != (now < after)
        }
        // Only a block that crosses rows is raised: re-adding a view delays its
        // first frames, so a row an insert pushes down would lag the new row
        // opening above it (cx-ai79).
        guard !passed.isEmpty else { return }
        if let top = list.subviews.last(where: { $0 is SidebarRowView }) {
            var anchor = top
            for row in layout.rows where block(row.key) {
                guard let view = list.rowViews[row.key], view !== anchor else { continue }
                list.addSubview(view, positioned: .above, relativeTo: anchor)
                anchor = view
            }
        }
        for view in passed {
            guard let hide = Motion.sidebar.passOverAnimation(.move) else { return }
            view.layer?.add(hide, forKey: "cmux.passOver")
        }
    }

    /// The rows that move with `key`: a workspace and its tab rows.
    private static func block(of key: SidebarRowKey) -> (SidebarRowKey) -> Bool {
        let workspace: WorkspaceID? = switch key {
        case let .workspace(id), let .tab(id, _): id
        default: nil
        }
        return { candidate in
            if candidate == key { return true }
            guard let workspace else { return false }
            switch candidate {
            case let .workspace(id), let .tab(id, _): return id == workspace
            default: return false
            }
        }
    }
}
