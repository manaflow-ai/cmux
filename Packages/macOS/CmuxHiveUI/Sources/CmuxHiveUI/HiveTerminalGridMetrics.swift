import AppKit
import SwiftUI

/// Cell geometry for fitting a remote terminal grid into a Canvas.
struct HiveTerminalGridMetrics: Equatable {
    let cellWidth: CGFloat
    let lineHeight: CGFloat
    let fontSize: CGFloat

    init(columns: Int, rows: Int, available: CGSize) {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        let referenceSize: CGFloat = 13
        let referenceFont = NSFont.monospacedSystemFont(ofSize: referenceSize, weight: .regular)
        let referenceAdvance = ("0" as NSString).size(withAttributes: [.font: referenceFont]).width
        let referenceLineHeight = NSLayoutManager().defaultLineHeight(for: referenceFont)
        let widthLimited = available.width / (CGFloat(columns) * referenceAdvance / referenceSize)
        let heightLimited = available.height / (CGFloat(rows) * referenceLineHeight / referenceSize)
        let size = max(min(widthLimited, heightLimited, 20), 4)
        fontSize = size
        cellWidth = referenceAdvance * size / referenceSize
        lineHeight = referenceLineHeight * size / referenceSize
    }

    func origin(row: Int, column: Int) -> CGPoint {
        CGPoint(x: CGFloat(column) * cellWidth, y: CGFloat(row) * lineHeight)
    }

    func font(bold: Bool, italic: Bool) -> Font {
        var font = Font.system(size: fontSize, design: .monospaced)
        if bold { font = font.bold() }
        if italic { font = font.italic() }
        return font
    }
}
