import AppKit
import CmuxNextDesign

/// The rows one `SidebarListView.apply` animates, all on one spring
/// (cx-bqm6): like a browser's vertical tabs, existing rows move, new rows
/// open their slot and removed rows close theirs, so no row overlaps another
/// or waits for it.
@MainActor
struct RowMotion {
    var targets: [(SidebarRowView, NSRect)]
    var appearing: [(SidebarRowView, NSRect)]
    var leaving: [(SidebarRowView, NSRect)]

    func run(in list: SidebarListView, from old: SidebarLayout, to layout: SidebarLayout, animated: Bool) {
        let moves = {
            for (view, target) in targets {
                view.animator().frame = target
                view.animator().alphaValue = 1
            }
        }
        guard animated else {
            Motion.withoutAnimation(moves)
            leaving.forEach { list.recycle($0.0) }
            return
        }
        // A moved selected row passes over its neighbours, not under them.
        if let key = list.selectedRowKey, let view = list.rowViews[key], old.row(for: key)?.y != layout.row(for: key)?.y,
           let top = list.subviews.last(where: { $0 is SidebarRowView }), top !== view {
            list.addSubview(view, positioned: .above, relativeTo: top)
        }
        Motion.animate(.move, in: list, {
            moves()
            for (view, target) in appearing {
                view.animator().frame = target
                view.animator().alphaValue = 1
            }
            for (view, end) in leaving {
                view.animator().alphaValue = 0
                view.animator().frame = end
            }
        }, completion: { [weak list, appearing, leaving] in
            guard let list else { return }
            for (view, _) in appearing { view.layer?.masksToBounds = false }
            for (view, _) in leaving where !list.rowViews.values.contains(where: { $0 === view }) { list.recycle(view) }
            list.pruneOffscreen()
        })
    }
}
