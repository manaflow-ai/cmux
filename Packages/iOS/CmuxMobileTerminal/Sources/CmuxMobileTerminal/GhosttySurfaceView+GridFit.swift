#if canImport(UIKit)
import CmuxMobileTerminalKit
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    /// Pure libghostty resize refinement; `nonisolated` so it runs on the
    /// off-main surface queue (it touches only the passed surface pointer).
    nonisolated static func fitSurfaceToGrid(
        _ surface: ghostty_surface_t,
        cols: Int,
        rows: Int,
        natural: ghostty_surface_size_s
    ) -> (requestedW: UInt32, requestedH: UInt32, actual: ghostty_surface_size_s) {
        let requested = TerminalGridFit.requestedPixelSize(
            columns: cols,
            rows: rows,
            natural: TerminalNaturalGridMeasurement(
                columns: Int(natural.columns),
                rows: Int(natural.rows),
                widthPx: Int(natural.width_px),
                heightPx: Int(natural.height_px),
                cellWidthPx: Int(natural.cell_width_px),
                cellHeightPx: Int(natural.cell_height_px)
            )
        )
        var requestedW = UInt32(requested.width)
        var requestedH = UInt32(requested.height)

        ghostty_surface_set_size(surface, requestedW, requestedH)
        var actual = ghostty_surface_size(surface)

        // Ghostty's grid calculation subtracts padding and floors partial cells,
        // so the reverse mapping has to be confirmed against Ghostty itself.
        // This keeps the iOS mirror on the exact daemon grid instead of
        // occasionally rendering one column short.
        var steps = 0
        // Bounded refinement: a few single-pixel nudges are enough to land on
        // the exact grid. A high cap let a fast-zoom storm run this loop tens
        // of thousands of times across frames and burn the main thread.
        // The render-grid apply fence needs the exact grid, so an overshoot
        // is corrected as well as a shortfall.
        while steps < 8,
              Int(actual.columns) != cols || Int(actual.rows) != rows {
            if Int(actual.columns) < cols {
                requestedW += 1
            } else if Int(actual.columns) > cols {
                let excess = UInt32(Int(actual.columns) - cols) * max(1, actual.cell_width_px)
                requestedW = requestedW > excess ? requestedW - excess : 1
            }
            if Int(actual.rows) < rows {
                requestedH += 1
            } else if Int(actual.rows) > rows {
                let excess = UInt32(Int(actual.rows) - rows) * max(1, actual.cell_height_px)
                requestedH = requestedH > excess ? requestedH - excess : 1
            }
            ghostty_surface_set_size(surface, requestedW, requestedH)
            actual = ghostty_surface_size(surface)
            steps += 1
        }

        return (requestedW, requestedH, actual)
    }

}
#endif
