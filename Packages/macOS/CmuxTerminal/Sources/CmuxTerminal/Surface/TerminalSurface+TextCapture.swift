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

/// The visible grid, one string per row, as drawn: soft-wrapped lines stay
/// split across their rows so row indices map straight to screen positions.
public struct TerminalViewportRows: Sendable, Equatable {
    /// Row texts from the top of the viewport, trailing blanks trimmed.
    public let rows: [String]
    /// Text baseline of each row in the surface view, in points from the
    /// view's top (padding included), as Ghostty reports it for the row's
    /// selection; `nil` when Ghostty could not place the row.
    public let rowBaselines: [Double?]
    /// Grid width in cells.
    public let columns: Int
    /// Cell height in backing pixels, as Ghostty reports it.
    public let cellHeightPixels: Int
}

extension TerminalSurface {
    /// Reads the viewport row by row.
    ///
    /// `readText(region: .viewport)` joins soft-wrapped rows into one line,
    /// which loses the row a piece of text sits on. Hover affordances need
    /// that row, so this reads each row as its own exact selection.
    ///
    /// - Parameter maxRows: Upper bound on rows read, for very tall panes.
    /// - Returns: The rows, or `nil` when the runtime is unavailable.
    @MainActor
    public func readViewportRows(maxRows: Int = 300) -> TerminalViewportRows? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "readViewportRows") else { return nil }
        let size = ghostty_surface_size(surface)
        let rowCount = min(Int(size.rows), maxRows)
        let columns = Int(size.columns)
        guard rowCount > 0, columns > 0 else { return nil }
        var rows: [String] = []
        var rowBaselines: [Double?] = []
        rows.reserveCapacity(rowCount)
        rowBaselines.reserveCapacity(rowCount)
        for row in 0..<rowCount {
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT,
                    coord: GHOSTTY_POINT_COORD_EXACT,
                    x: 0,
                    y: UInt32(row)
                ),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT,
                    coord: GHOSTTY_POINT_COORD_EXACT,
                    x: UInt32(columns - 1),
                    y: UInt32(row)
                ),
                rectangle: false
            )
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &text) else {
                rows.append("")
                rowBaselines.append(nil)
                continue
            }
            rowBaselines.append(text.tl_px_y >= 0 ? text.tl_px_y : nil)
            if let pointer = text.text, text.text_len > 0 {
                let data = Data(bytes: pointer, count: Int(text.text_len))
                rows.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            } else {
                rows.append("")
            }
            ghostty_surface_free_text(surface, &text)
        }
        return TerminalViewportRows(
            rows: rows,
            rowBaselines: rowBaselines,
            columns: columns,
            cellHeightPixels: Int(size.cell_height_px)
        )
    }
}
