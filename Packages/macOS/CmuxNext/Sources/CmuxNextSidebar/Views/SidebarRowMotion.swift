import AppKit
import CmuxNextDesign

/// The rows one `SidebarListView.apply` animates, all on one spring
/// (cx-bqm6; hq-1d: on the window's MotionClock, `SidebarRowSprings`): like
/// a browser's vertical tabs, existing rows move, new rows open their slot
/// and removed rows close theirs, so no row overlaps another or waits for
/// it. A row keeps its final size from the first frame and only its origin
/// and its visible height spring. Group lines run on the same springs, so a
/// line ends at its group's last row in every frame (cx-ai79).
@MainActor
struct RowMotion {
    var targets: [(SidebarRowView, NSRect)]
    var appearing: [(SidebarRowView, NSRect)]
    var leaving: [(SidebarRowView, NSRect)]
    var lines: (changes: () -> Void, leaving: [NSView])

    func run(in list: SidebarListView, from old: SidebarLayout, to layout: SidebarLayout, animated: Bool) {
        let springs = list.rowSprings
        // Not animated, or Reduce Motion: rows take their places in one step, with no crossfade
        // standing in for the motion (DESIGN P6): no movement, and nothing a person must wait out.
        guard animated, Motion.animatesMovement else {
            Motion.withoutAnimation {
                for (view, target) in targets + appearing {
                    springs.cancel(view)
                    view.frame = target
                    view.alphaValue = 1
                }
                for (view, _) in appearing { view.clipsToBounds = false }
                lines.changes()
            }
            leaving.forEach { list.recycle($0.0) }
            lines.leaving.forEach { $0.removeFromSuperview() }
            return
        }
        passOver(in: list, from: old, to: layout)
        Motion.withoutAnimation {
            for (view, target) in targets {
                view.alphaValue = 1
                springs.row(view, to: target)
            }
            for (view, target) in appearing {
                // `apply` placed it at its start (its run's top, zero height): it lays out at its
                // final size now and opens through its mask.
                let start = view.frame
                view.alphaValue = 1
                let open = view.opens
                springs.row(view, from: start, to: target) { [view] in
                    if view.opens == open { view.clipsToBounds = false }
                }
            }
            for (view, end) in leaving {
                let shown = springs.presented(view)
                springs.row(view, from: shown, to: NSRect(origin: end.origin, size: view.frame.size), visible: end.height) { [weak list, view] in
                    guard let list, !list.rowViews.values.contains(where: { $0 === view }) else { return }
                    list.recycle(view)
                }
            }
            lines.changes()
        }
        springs.whenSettled { [weak list, leavingLines = lines.leaving] in
            leavingLines.forEach { $0.removeFromSuperview() }
            list?.pruneOffscreen()
        }
        springs.start()
    }

    /// Places a row that scrolled into view. One still opening (the viewport
    /// held still for an insert above it, then scrolled to it) opens from zero
    /// height at its slot instead of showing whole over the rows still making
    /// room (cx-ai79).
    static func place(_ view: SidebarRowView, at target: NSRect, opening: Bool, hidden: Bool, in list: SidebarListView) {
        guard opening, !hidden, Motion.animatesMovement else {
            list.rowSprings.cancel(view)
            view.frame = target
            view.alphaValue = hidden ? 0 : 1
            return
        }
        view.layer?.removeAllAnimations()
        view.alphaValue = 1
        view.clipsToBounds = true
        view.opens += 1
        let open = view.opens
        list.rowSprings.row(view, from: NSRect(x: target.minX, y: target.minY, width: target.width, height: 0), to: target) { [view] in
            if view.opens == open { view.clipsToBounds = false }
        }
        list.rowSprings.start()
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
            guard let hide = Motion.passOverAnimation(.move) else { return }
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
