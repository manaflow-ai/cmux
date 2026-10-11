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

    /// Captures a bounded VT reconstruction of the newest terminal rows.
    ///
    /// Ghostty formats only the requested tail while it holds the surface
    /// lock, so callers that already have a row and byte budget do not need to
    /// export the entire scrollback and trim it afterward.
    ///
    /// - Parameters:
    ///   - maxRows: Maximum number of physical history/current-screen rows.
    ///   - maxBytes: Hard maximum for the formatted VT output.
    /// - Returns: UTF-8 VT text, or `nil` when the runtime cannot provide it.
    @MainActor
    public func readBoundedScreenTailVT(maxRows: Int, maxBytes: Int) -> String? {
        guard maxRows > 0,
              maxBytes > 0,
              let maxRows = UInt(exactly: maxRows),
              let maxBytes = UInt(exactly: maxBytes),
              let surface = liveSurfaceForGhosttyAccess(
                reason: "readBoundedScreenTailVT"
              ) else {
            return nil
        }

        var text = ghostty_text_s()
        guard ghostty_surface_read_screen_tail_vt(
            surface,
            maxRows,
            maxBytes,
            &text
        ) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let pointer = text.text,
              let byteCount = Int(exactly: text.text_len),
              byteCount > 0 else {
            return ""
        }
        let rawData = Data(bytes: pointer, count: byteCount)
        return String(decoding: rawData, as: UTF8.self)
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
