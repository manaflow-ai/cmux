public import CmuxNextTerminalFind
import GhosttyNextKit

// The find bar drives Ghostty's search bindings on whichever surface is
// live (a replay swaps it). Ghostty reports results as SEARCH_TOTAL and
// SEARCH_SELECTED, which TerminalSurfaceView forwards to `find`.
extension TerminalSession: TerminalFindTarget {
    public func setSearchNeedle(_ needle: String) {
        _ = surfaceView.performBindingAction("search:\(needle)")
    }

    public func navigateSearch(_ direction: TerminalFindDirection) {
        // Ghostty scrolls the selected match into view.
        _ = surfaceView.performBindingAction(direction == .next ? "navigate_search:next" : "navigate_search:previous")
    }

    public func endSearch() {
        _ = surfaceView.performBindingAction("end_search")
    }

    public func clearSelection() {
        guard let surface = surfaceView.surface else { return }
        _ = ghostty_surface_clear_selection(surface)
    }

    /// Copy mode owns the selection while it is active (find opened with
    /// its `/` must not clear a `v` selection).
    public var isSelectionPinned: Bool { surfaceView.copyMode.isActive }

    public func focusTerminal() {
        focus()
    }

    public func showFindBar() {
        view.showFindBar(find)
    }

    /// Scrolls a daemon match into view and selects it. The daemon counts rows from the newest; the
    /// mirror's rows are the scrollbar's (0 the oldest it keeps), so the match is at
    /// `total - rowsFromBottom`. Its text is read back from the selection: a mirror that shifted or
    /// holds less history says no, and the bar falls back to Ghostty's search.
    public func revealHistoryMatch(_ match: TerminalFindMatch, columns: Int) -> Bool {
        guard let surface = surfaceView.surface, let bar = model.scrollbar else { return false }
        let total = Int(bar.totalRows), visible = max(Int(bar.visibleRows), 1)
        let row = total - match.rowsFromBottom
        guard row >= 0, row < total, match.startColumn < max(columns, 1) else { return false }
        // A third of the way down the viewport, so the lines before the match stay in view.
        let top = min(max(row - visible / 3, 0), max(total - visible, 0))
        _ = surfaceView.performBindingAction("scroll_to_row:\(top)")
        guard let line = UInt16(exactly: row - top), let column = UInt16(exactly: match.startColumn),
              ghostty_surface_select_viewport_cell(surface, column, line) else { return false }
        for _ in 1..<min(match.cellCount(columns: columns), 4096) { _ = surfaceView.performBindingAction("adjust_selection:right") }
        let selected = TerminalSelection.read(surface)?.text.replacingOccurrences(of: "\n", with: "")
        guard selected == match.text.replacingOccurrences(of: "\n", with: "") else {
            _ = ghostty_surface_clear_selection(surface)
            return false
        }
        return true
    }
}
