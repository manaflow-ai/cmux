import CmuxTerminal
import Foundation

extension CloudTuiManualIOGrid {
    /// The grid a pane sample may report to the remote PTY, or nil for a
    /// stale bootstrap sample. A runtime surface can be created in the hidden
    /// 800×600 startup window before AppKit lays out the real pane; checking
    /// the reported pixel size against the attached view keeps that transient
    /// grid from becoming the remote PTY's authority.
    static func usable(
        from sample: TerminalSurfaceRawSizingSample,
        validatePanePixels: Bool
    ) -> CloudTuiManualIOGrid? {
        guard let grid = CloudTuiManualIOGrid(columns: sample.columns, rows: sample.rows),
              sample.cellWidthPx > 0,
              sample.cellHeightPx > 0,
              sample.surfaceWidthPx > 0,
              sample.surfaceHeightPx > 0 else {
            return nil
        }
        guard validatePanePixels else { return grid }
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
        return grid
    }
}
