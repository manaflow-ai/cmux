import AppKit

/// A new workspace's row view is made before its key, as Chrome keeps a spare renderer process for the next tab
/// (`SpareRenderProcessHostManager`, content/browser/renderer_host/spare_render_process_host_manager_impl.cc): hidden
/// `WorkspaceRowView`s wait in the list, made one per committed frame while the sidebar shows, and a new workspace row
/// with no view of its own takes one (`SidebarRowViewPool.take`). Three wait in a window with one space; a window
/// with more spaces keeps a page of them (`spareRowsWanted`), so the rows of a space shown for the first time take
/// views made before the key and leave the other space its own.
/// Cmd-N's turn then only configures and places its row, also in a burst faster than the frames (key repeat): on the
/// bench the view's `init` was 5.7 ms of the 10.4 ms sidebar redraw in the key's turn (SHORTCUT LATENCY SL-2). A spare
/// never showed a row, so a new row still gets a view that no other row showed (cx-ai79). It waits as a parked view
/// does: hidden in the list, already in the window. A hidden sidebar or window makes none (hidden windows do no view
/// work); it makes them once it shows again.
extension SidebarListViewComponents {
    /// The key the spares carry until a row takes one; no row has it.
    static let spareRowKey = SidebarRowKey.workspace(WorkspaceID("sidebar.spare-row"))

    /// The spares the list keeps: three for new workspaces (a burst of Cmd-N). With more than one space, as many as
    /// make a page of workspace rows together with the parked views: the views a space shown for the first time
    /// takes. Once each of two spaces has its views (one page shown, one parked) the count goes back to three.
    var spareRowsWanted: Int {
        guard model.profiles.count > 1 else { return SidebarRowViewPool.spareCount }
        return max(SidebarRowViewPool.spareCount, rowPool.pageRows - rowPool.parkedWorkspaceRows)
    }

    /// Whether this list makes spares now: it keeps them, it shows (no hidden ancestor, its window on screen and not
    /// covered: hidden windows do no view work), and it holds fewer than `spareRowsWanted`.
    var wantsSpareRow: Bool {
        guard keepsSpareRow, rowPool.spares.count < spareRowsWanted, let window, !isHiddenOrHasHiddenAncestor else {
            return false
        }
        return windowShowsRows(window)
    }

    /// Makes one spare after this run-loop pass committed its frame, when the list wants one; each spare made schedules
    /// the next for the pass after, so no pass makes more than one row view.
    func scheduleSpareRow() {
        guard wantsSpareRow, !spareRowScheduled else { return }
        spareRowScheduled = true
        afterFrameCommit { [weak self] in
            guard let self else { return }
            self.spareRowScheduled = false
            self.makeSpareRow()
        }
    }

    /// A spare, hidden in the list where a new row's view goes, above the drag gap (its controls register with the
    /// window now, not in a key's turn): a scroll that takes it shows it in place, as it shows a parked view.
    func makeSpareRow() {
        guard wantsSpareRow else { return }
        let view = WorkspaceRowView(key: Self.spareRowKey)
        SidebarPerfCounters.add(.spareRowViews)
        view.isHidden = true
        addSubview(view, positioned: .above, relativeTo: decorations)
        rowPool.spares.append(view)
        scheduleSpareRow()
    }
}
