import AppKit

/// A new workspace's row view is made before its key, as Chrome keeps a spare renderer process for the next tab
/// (`SpareRenderProcessHostManager`): one hidden `WorkspaceRowView` waits in the list, made after a frame committed,
/// and the next workspace row with no view of its own takes it (`SidebarRowViewPool.take`). Cmd-N's turn then only
/// configures and places its row: on the bench the view's `init` was 5.7 ms of the 10.4 ms sidebar redraw in the
/// key's turn (SHORTCUT LATENCY SL-2). The spare never showed a row, so a new row still gets a view that no other
/// row showed (cx-ai79). It waits as a parked view does: hidden in the list, already in the window.
extension SidebarListViewComponents {
    /// The key the spare carries until a row takes it; no row has it.
    static let spareRowKey = SidebarRowKey.workspace(WorkspaceID("sidebar.spare-row"))

    /// Makes the spare after this pass's frame committed, when this list keeps one and has none.
    func scheduleSpareRow() {
        guard keepsSpareRow, rowPool.spare == nil, !spareRowScheduled, window != nil else { return }
        spareRowScheduled = true
        afterFrameCommit { [weak self] in
            guard let self else { return }
            self.spareRowScheduled = false
            self.makeSpareRow()
        }
    }

    /// The spare, hidden in the list under the rows (its controls register with the window now, not in a key's
    /// turn); the apply that takes it puts it with the rows.
    func makeSpareRow() {
        guard keepsSpareRow, rowPool.spare == nil, window != nil else { return }
        let view = WorkspaceRowView(key: Self.spareRowKey)
        SidebarPerfCounters.add(.spareRowViews)
        view.isHidden = true
        addSubview(view, positioned: .below, relativeTo: decorations)
        rowPool.spare = view
    }
}
