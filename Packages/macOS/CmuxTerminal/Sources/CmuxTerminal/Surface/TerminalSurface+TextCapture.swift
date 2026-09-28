import Foundation
import GhosttyKit

extension TerminalSurface {
    /// Captures one semantic text region from the live Ghostty surface.
    ///
    /// - Parameter region: The terminal region to capture.
    /// - Returns: UTF-8 text, an empty string for an empty region, or `nil` when
    ///   the runtime is unavailable or Ghostty refuses the capture.
    @MainActor
    public func readText(region: TerminalTextRegion) -> String? {
        guard let surface = liveSurfaceForGhosttyAccess(
            reason: "readText"
        ) else { return nil }
        return readText(surface: surface, region: region)
    }

    /// Captures every screen row (scrollback plus active area), one output
    /// line per physical row: soft-wrapped lines are not joined, so line `i`
    /// of the result is screen row `i`, the row space of the scrollbar's
    /// `offset` and `total`.
    ///
    /// - Returns: The rows, or `nil` when the runtime is unavailable or
    ///   Ghostty refuses the capture.
    @MainActor
    public func readScreenRows() -> String? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "readScreenRows") else {
            return nil
        }
        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        // A rectangle selection keeps one line per physical row.
        return readText(
            surface: surface,
            selection: ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: true)
        )
    }

    private func readText(
        surface: ghostty_surface_t,
        region: TerminalTextRegion
    ) -> String? {
        let topLeft = ghostty_point_s(
            tag: region.pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: region.pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )
        return readText(surface: surface, selection: selection)
    }

    private func readText(
        surface: ghostty_surface_t,
        selection: ghostty_selection_s
    ) -> String? {
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let pointer = text.text, text.text_len > 0 else { return "" }
        let rawData = Data(bytes: pointer, count: Int(text.text_len))
        return String(decoding: rawData, as: UTF8.self)
    }
}
