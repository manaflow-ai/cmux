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
        let passed = animated ? passOver(in: list, from: old, to: layout) : []
        let moves = {
            for (view, target) in targets {
                view.animator().frame = target
                if !passed.contains(where: { $0 === view }) { view.animator().alphaValue = 1 }
            }
        }
        guard animated else {
            Motion.withoutAnimation {
                moves()
                lines.changes()
            }
            leaving.forEach { list.recycle($0.0) }
            lines.leaving.forEach { $0.removeFromSuperview() }
            return
        }
        Motion.animate(.move, in: list, {
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
        }, completion: { [weak list, appearing, leaving, passed, leavingLines = lines.leaving] in
            leavingLines.forEach { $0.removeFromSuperview() }
            Motion.animate(.fadeIn, in: list) { passed.forEach { $0.animator().alphaValue = 1 } }
            guard let list else { return }
            for (view, _) in appearing { view.clipsToBounds = false }
            for (view, _) in leaving where !list.rowViews.values.contains(where: { $0 === view }) { list.recycle(view) }
            list.pruneOffscreen()
        })
    }

    /// A moved selected row (with its workspace's tab rows) passes over the
    /// rows it trades places with: it draws above them, and each row it
    /// crosses hides at once and fades back in after the move settles, so
    /// its translucent selection fill never shows a title through it
    /// (cx-bqm6, cx-ai79). Returns the hidden rows.
    private func passOver(in list: SidebarListView, from old: SidebarLayout, to layout: SidebarLayout) -> [SidebarRowView] {
        guard let key = list.selectedRowKey, let before = old.row(for: key)?.y, let after = layout.row(for: key)?.y,
              before != after else { return [] }
        let block = Self.block(of: key)
        if let top = list.subviews.last(where: { $0 is SidebarRowView }) {
            var anchor = top
            for row in layout.rows where block(row.key) {
                guard let view = list.rowViews[row.key], view !== anchor else { continue }
                list.addSubview(view, positioned: .above, relativeTo: anchor)
                anchor = view
            }
        }
        guard Motion.animatesMovement else { return [] }
        let passed = targets.map(\.0).filter { view in
            guard !block(view.key), let was = old.row(for: view.key)?.y, let now = layout.row(for: view.key)?.y else { return false }
            return (was < before) != (now < after)
        }
        Motion.withoutAnimation { passed.forEach { $0.alphaValue = 0 } }
        return passed
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
