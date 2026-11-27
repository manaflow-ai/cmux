import Foundation
import GhosttyNextKit

/// Toggle Terminal and Chat's place on the terminal face: a swap lands at the same turn in the
/// other view, both ways (Leo, 2026-11-12). Rows are the scrollbar's (Ghostty's scrollbar action):
/// row 0 the oldest the screen keeps, the viewport's top at `offsetRows`, and Ghostty's
/// `scroll_to_row` takes the same numbers.
extension TerminalSession {
    /// The viewport's top row, its rows, the screen's rows and whether the viewport shows the
    /// newest; nil before Ghostty reports a scrollbar. Reads the last report: no surface lock.
    public func togglePlaceViewport() -> (top: Int, visible: Int, total: Int, atBottom: Bool)? {
        guard let bar = model.scrollbar else { return nil }
        return (Int(bar.offsetRows), Int(bar.visibleRows), Int(bar.totalRows), bar.offsetRows + bar.visibleRows >= bar.totalRows)
    }

    /// Screen rows, one line per row, and the grid's columns: from the viewport's top or the
    /// screen's start, through the viewport's bottom or the newest row. Takes Ghostty's surface
    /// lock: once per swap that needs it, never per frame. Ghostty addresses no other window of a
    /// long history (an exact screen point's row is clamped to the grid), so a caller bounds the
    /// read by where it puts the viewport.
    public func togglePlaceRead(fromViewportTop: Bool, throughViewportBottom: Bool) -> (screen: String, columns: Int)? {
        let start = fromViewportTop ? ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0)
            : ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let end = ghostty_point_s(tag: throughViewportBottom ? GHOSTTY_POINT_VIEWPORT : GHOSTTY_POINT_SCREEN,
                                  coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        guard let screen = rowsText(surfaceView, from: start, to: end), let grid = surfaceView.currentGrid else { return nil }
        return (screen, grid.columns)
    }

    /// Scrolls row `row` to the viewport's top, or to the newest rows for nil.
    public func togglePlaceScroll(toRow row: Int?) {
        _ = surfaceView.performBindingAction(row.map { "scroll_to_row:\($0)" } ?? "scroll_to_bottom")
    }
}

/// The rows from `start` to `end` as a rectangle: one line per row, so line N is row N of the read
/// (a plain read joins soft-wrapped rows and loses that). A free function, not a
/// ``TerminalSurfaceView`` member: that type is over its size budget (check-no-godfiles.sh).
@MainActor
func rowsText(_ view: TerminalSurfaceView, from start: ghostty_point_s, to end: ghostty_point_s) -> String? {
    guard let surface = view.surface else { return nil }
    let selection = ghostty_selection_s(top_left: start, bottom_right: end, rectangle: true)
    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let pointer = text.text, text.text_len > 0 else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
}
