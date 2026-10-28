import AppKit

/// What a drag shows before the layout carries it (gesture state; the model keeps no observed copy, rows.md Z1):
/// a row divider drag's heights, and a divider or column-edge drag's ratios and widths. It shows until the next
/// layout arrives after the drag ended (`ScreenContentView.update`).
struct ScreenDragPreview {
    var rows: (column: ColumnID, heights: [RowHeight])?
    /// The ratios and widths the drag sets now, clamped as the model clamps them.
    var values: [DividerDragValue] = []

    var isEmpty: Bool { rows == nil && values.isEmpty }

    /// `layout` with the drag's values on it.
    func applied(to layout: ScreenLayout) -> ScreenLayout {
        var shown = rows.map { layout.settingRowHeights($0.heights, for: $0.column) } ?? layout
        for value in values {
            switch value {
            case let .ratio(split, ratio):
                shown = shown.settingRatio(min(max(ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound), for: split)
            case let .width(column, width):
                let range = ColumnWidthPreset.widthRange
                shown = shown.settingWidth(min(max(width, range.lowerBound), range.upperBound), for: column)
            }
        }
        return shown
    }
}
