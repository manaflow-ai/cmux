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
}
