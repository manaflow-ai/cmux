import Foundation
import GhosttyNextKit

/// Toggle Terminal and Chat's place on the terminal face: a swap lands at the same turn in the
/// other view, both ways (Leo, 2026-11-12). Rows are the scrollbar's (Ghostty's scrollbar action):
/// row 0 the oldest the screen keeps, the viewport's top at `offsetRows`, and Ghostty's
/// `scroll_to_row` takes the same numbers.
extension TerminalSession {
    /// The viewport's top row and whether it shows the newest rows; nil before Ghostty reports a
    /// scrollbar. Reads the last report: no surface lock.
    public func togglePlaceViewport() -> (top: Int, atBottom: Bool)? {
        guard let bar = model.scrollbar else { return nil }
        return (Int(bar.offsetRows), bar.offsetRows + bar.visibleRows >= bar.totalRows)
    }

    /// The whole screen, history and active area, one line per row, and the grid's columns. Takes
    /// Ghostty's surface lock: once per swap that needs it, never per frame.
    public func togglePlaceScreen() -> (screen: String, columns: Int)? {
        guard let screen = surfaceView.screenRowsText(), let grid = surfaceView.currentGrid else { return nil }
        return (screen, grid.columns)
    }

    /// Scrolls row `row` to the viewport's top, or to the newest rows for nil.
    public func togglePlaceScroll(toRow row: Int?) {
        _ = surfaceView.performBindingAction(row.map { "scroll_to_row:\($0)" } ?? "scroll_to_bottom")
    }
}

extension TerminalSurfaceView {
    /// Every row of the screen, history and active area, as a rectangle (one line per row, so line
    /// N is scrollbar row N; a plain read joins soft-wrapped rows and loses that).
    func screenRowsText() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: true
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }
}
