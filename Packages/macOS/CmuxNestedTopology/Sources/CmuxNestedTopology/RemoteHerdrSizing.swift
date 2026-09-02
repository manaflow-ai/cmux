/// Feed-forward client-size claim (tmux ``updateClientSize`` analogue).
///
/// The claim reads only window geometry, chrome constants, and cell metrics —
/// never a measured pane frame. That is the ssh-tmux invariant that prevents
/// the container from growing each pass.
///
/// Construct at the mirror composition seam rather than calling ambient statics.
public struct RemoteHerdrSizing: Sendable {
    /// Creates a sizing helper.
    public init() {}

    /// Computes the grid to claim from Herdr for one mirrored tab.
    public func clientGrid(
        contentWidth: Double,
        contentHeight: Double,
        cellWidth: Double,
        cellHeight: Double,
        chromeWidth: Double = 0,
        chromeHeight: Double = 0
    ) -> (cols: Int, rows: Int)? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let availableWidth = contentWidth - chromeWidth
        let availableHeight = contentHeight - chromeHeight
        guard availableWidth > 0, availableHeight > 0 else { return nil }
        let cols = Int(availableWidth / cellWidth)
        let rows = Int(availableHeight / cellHeight)
        guard cols >= 1, rows >= 1 else { return nil }
        return (cols, rows)
    }

    /// Converts a dragged first-child extent (points) into a cell span for
    /// ``pane.resize`` (tmux divider-drag → ``resize-pane``).
    public func resizeCells(
        draggedExtent: Double,
        axisSpan: Double,
        totalCells: Int
    ) -> Int {
        guard axisSpan > 0, totalCells >= 1 else { return 1 }
        let fraction = min(0.95, max(0.05, draggedExtent / axisSpan))
        let cells = Int((fraction * Double(totalCells)).rounded())
        // totalCells == 1 must still yield 1 (never 0) for pane.resize.
        return min(max(1, totalCells - 1), max(1, cells))
    }
}
