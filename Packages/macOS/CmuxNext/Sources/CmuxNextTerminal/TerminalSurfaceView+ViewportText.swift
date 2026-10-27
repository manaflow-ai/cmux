public import AppKit
import GhosttyNextKit

extension TerminalSurfaceView {
    /// The text the mirror shows in its viewport, for diagnostics
    /// (`debug.surfaces text:true`, relaunch-e2e.py): proves the view renders
    /// what the daemon holds. Takes Ghostty's surface lock; never call it on
    /// a typing or drawing path.
    public func viewportText() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        return unsafe GhosttyTextRead(surface, selection: selection)?.string
    }
}
