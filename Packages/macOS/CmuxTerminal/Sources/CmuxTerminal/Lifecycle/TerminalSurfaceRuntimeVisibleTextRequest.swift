internal import GhosttyKit

/// A row-bounded plain-text read serialized with native surface teardown.
///
/// The request selects only the current active-screen suffix. Scrollback and VT
/// styling never cross this boundary. `@unchecked Sendable` is limited to
/// transporting the borrowed surface pointer onto the teardown coordinator.
struct TerminalSurfaceRuntimeVisibleTextRequest: @unchecked Sendable {
    let surface: ghostty_surface_t
    let startRow: UInt32
    let maxBytes: Int

    func read() -> String? {
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_ACTIVE,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0,
                y: startRow
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_ACTIVE,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let byteCount = Int(exactly: text.text_len), byteCount <= maxBytes else { return nil }
        guard byteCount > 0, let bytes = text.text else { return "" }
        return String(
            decoding: UnsafeRawBufferPointer(start: bytes, count: byteCount),
            as: UTF8.self
        )
    }
}
