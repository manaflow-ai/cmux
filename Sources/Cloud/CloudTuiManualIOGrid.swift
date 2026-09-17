import CmuxTerminal
import Foundation

/// A cell grid sampled from the native Ghostty pane.
struct CloudTuiManualIOGrid: Equatable, Sendable {
    let columns: Int
    let rows: Int

    /// Creates a bounded, usable terminal grid.
    init?(columns: Int, rows: Int) {
        guard (2...10_000).contains(columns), (2...10_000).contains(rows) else {
            return nil
        }
        self.columns = columns
        self.rows = rows
    }

    /// Rejects a stale bootstrap sample. A runtime surface can be created in
    /// the hidden 800×600 startup window before AppKit lays out the real pane;
    /// checking the reported pixel size against the attached view keeps that
    /// transient grid from becoming the remote PTY's authority.
    init?(
        sample: TerminalSurfaceRawSizingSample,
        validatePanePixels: Bool
    ) {
        guard let grid = CloudTuiManualIOGrid(columns: sample.columns, rows: sample.rows),
              sample.cellWidthPx > 0,
              sample.cellHeightPx > 0,
              sample.surfaceWidthPx > 0,
              sample.surfaceHeightPx > 0 else {
            return nil
        }
        guard validatePanePixels else {
            self = grid
            return
        }
        guard let bounds = sample.viewBoundsPt,
              let scale = sample.backingScale,
              bounds.width > 2,
              bounds.height > 2,
              bounds.width.isFinite,
              bounds.height.isFinite,
              scale.isFinite,
              scale > 0 else { return nil }
        let expectedWidth = max(1, Int(floor(bounds.width * scale)))
        let expectedHeight = max(1, Int(floor(bounds.height * scale)))
        let widthTolerance = max(4, max(1, sample.cellWidthPx) * 2)
        let heightTolerance = max(4, max(1, sample.cellHeightPx) * 2)
        guard abs(sample.surfaceWidthPx - expectedWidth) <= widthTolerance,
              abs(sample.surfaceHeightPx - expectedHeight) <= heightTolerance else {
            return nil
        }
        self = grid
    }
}
