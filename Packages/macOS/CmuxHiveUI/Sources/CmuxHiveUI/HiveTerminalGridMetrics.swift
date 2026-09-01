import AppKit
import SwiftUI

/// Cell geometry for fitting a remote terminal grid into a Canvas.
struct HiveTerminalGridMetrics: Equatable {
    private static let referenceSize: CGFloat = 13
    private static let referenceFont = NSFont.monospacedSystemFont(
        ofSize: referenceSize,
        weight: .regular
    )
    private static let referenceAdvance =
        ("0" as NSString).size(withAttributes: [.font: referenceFont]).width
    private static let referenceLineHeight =
        NSLayoutManager().defaultLineHeight(for: referenceFont)

    let cellWidth: CGFloat
    let lineHeight: CGFloat
    let fontSize: CGFloat

    init(columns: Int, rows: Int, available: CGSize) {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        let widthLimited = available.width / (CGFloat(columns) * Self.referenceAdvance / Self.referenceSize)
        let heightLimited = available.height / (CGFloat(rows) * Self.referenceLineHeight / Self.referenceSize)
        let size = max(min(widthLimited, heightLimited, 20), 4)
        fontSize = size
        cellWidth = Self.referenceAdvance * size / Self.referenceSize
        lineHeight = Self.referenceLineHeight * size / Self.referenceSize
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
