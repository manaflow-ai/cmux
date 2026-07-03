#if os(iOS)
import CoreGraphics

struct TerminalAccessoryDockMetrics {
    static let nubSize: CGFloat = 28
    static let bottomPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 4

    let rowCount: Int

    var rowsHeight: CGFloat {
        let clampedRowCount = min(
            max(rowCount, TerminalAccessoryConfiguration.minimumRowCount),
            TerminalAccessoryConfiguration.maximumRowCount
        )
        let rows = CGFloat(clampedRowCount)
        return rows * Self.nubSize + max(0, rows - 1) * Self.rowSpacing
    }

    var buttonRowHeight: CGFloat {
        rowsHeight + Self.bottomPadding
    }
}
#endif
