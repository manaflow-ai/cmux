import AppKit
import SwiftUI

/// Cell geometry for fitting a remote terminal grid into a Canvas.
struct HiveTerminalGridMetrics: Equatable {
    private static let referenceSize: CGFloat = 13
    // Cache only Sendable scalar measurements, not a shared AppKit object.
    private static let referenceMetrics: (advance: CGFloat, lineHeight: CGFloat) = {
        let font = NSFont.monospacedSystemFont(ofSize: referenceSize, weight: .regular)
        return (
            ("0" as NSString).size(withAttributes: [.font: font]).width,
            NSLayoutManager().defaultLineHeight(for: font)
        )
    }()

    let cellWidth: CGFloat
    let lineHeight: CGFloat
    let fontSize: CGFloat

    init(columns: Int, rows: Int, available: CGSize) {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        let widthLimited = available.width / (CGFloat(columns) * Self.referenceMetrics.advance / Self.referenceSize)
        let heightLimited = available.height / (CGFloat(rows) * Self.referenceMetrics.lineHeight / Self.referenceSize)
        let size = max(min(widthLimited, heightLimited, 20), 4)
        fontSize = size
        cellWidth = Self.referenceMetrics.advance * size / Self.referenceSize
        lineHeight = Self.referenceMetrics.lineHeight * size / Self.referenceSize
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
