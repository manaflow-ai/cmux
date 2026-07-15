import CMUXMobileCore
import CmuxMobileShell
import CoreGraphics

/// Pure terminal-column geometry used by the thumbnail Canvas and tests.
struct TerminalGridThumbnailLayout: Equatable {
    let columns: Int
    let rows: Int
    let activeScreen: MobileTerminalRenderGridFrame.Screen
    let lines: [PreviewGridLine]

    init(snapshot: PreviewGridSnapshot) {
        columns = snapshot.columns
        rows = snapshot.rows
        activeScreen = snapshot.activeScreen
        lines = snapshot.lines
    }

    func runs(in size: CGSize) -> [TerminalGridThumbnailRun] {
        guard columns > 0, rows > 0, size.width > 0, size.height > 0 else { return [] }
        let cellSize = CGSize(
            width: size.width / CGFloat(columns),
            height: size.height / CGFloat(rows)
        )
        return lines.flatMap { line in
            line.spans.map { span in
                TerminalGridThumbnailRun(
                    row: line.row,
                    column: span.column,
                    cellWidth: span.cellWidth,
                    frame: CGRect(
                        x: CGFloat(span.column) * cellSize.width,
                        y: CGFloat(line.row) * cellSize.height,
                        width: CGFloat(span.cellWidth) * cellSize.width,
                        height: cellSize.height
                    ),
                    text: span.text,
                    style: span.style
                )
            }
        }
    }
}
