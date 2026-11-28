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
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }
}

/// One viewport row's text, as `ghostty_surface_read_text` formats it (a
/// wide glyph's spacer cell adds nothing). Takes Ghostty's surface lock.
func ghosttyViewportRowText(_ surface: ghostty_surface_t, row: Int, columns: Int) -> String {
    guard let y = UInt32(exactly: row), let lastColumn = UInt32(exactly: max(columns - 1, 0)) else { return "" }
    let selection = ghostty_selection_s(
        top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: y),
        bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: lastColumn, y: y),
        rectangle: false
    )
    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let pointer = text.text, text.text_len > 0 else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
}
