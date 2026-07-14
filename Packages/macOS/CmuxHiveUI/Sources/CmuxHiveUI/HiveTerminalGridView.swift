public import CmuxHive
import CMUXMobileCore
public import SwiftUI

/// Draws one ``HiveTerminalGridModel`` snapshot as a fixed-cell text grid.
///
/// A `Canvas` places each styled span at its absolute cell rectangle (column ×
/// cell width, row × line height), so alignment matches the remote terminal
/// exactly for fixed-advance text; wide glyphs draw per-character at their
/// declared cell width. The font size auto-fits the available space to the
/// remote grid's columns × rows.
public struct HiveTerminalGridView: View {
    private let grid: HiveTerminalGridModel

    /// Creates a grid view over one immutable grid snapshot.
    public init(grid: HiveTerminalGridModel) {
        self.grid = grid
    }

    public var body: some View {
        GeometryReader { proxy in
            let metrics = HiveTerminalGridMetrics(
                columns: grid.columns,
                rows: grid.rows,
                available: proxy.size
            )
            Canvas { context, _ in
                draw(in: &context, metrics: metrics)
            }
        }
        .background(HiveTerminalColor.parse(grid.terminalBackground) ?? HiveTerminalColor.fallbackBackground)
    }

    private func draw(in context: inout GraphicsContext, metrics: HiveTerminalGridMetrics) {
        guard grid.hasContent else { return }
        let defaultForeground = HiveTerminalColor.parse(grid.terminalForeground)
            ?? HiveTerminalColor.fallbackForeground
        let defaultBackground = HiveTerminalColor.parse(grid.terminalBackground)
            ?? HiveTerminalColor.fallbackBackground
        drawCursorBackground(in: &context, metrics: metrics)
        for row in 0..<min(grid.rows, grid.rowSpans.count) {
            for span in grid.rowSpans[row] {
                drawSpan(
                    span,
                    row: row,
                    in: &context,
                    metrics: metrics,
                    defaultForeground: defaultForeground,
                    defaultBackground: defaultBackground
                )
            }
        }
        drawCursorOutline(in: &context, metrics: metrics)
    }

    private func drawSpan(
        _ span: HiveTerminalGridModel.Span,
        row: Int,
        in context: inout GraphicsContext,
        metrics: HiveTerminalGridMetrics,
        defaultForeground: Color,
        defaultBackground: Color
    ) {
        let style = span.style
        var foreground = HiveTerminalColor.parse(style.foreground) ?? defaultForeground
        var background = HiveTerminalColor.parse(style.background)
        if style.inverse {
            let swappedForeground = background ?? defaultBackground
            background = foreground
            foreground = swappedForeground
        }
        if style.invisible { return }
        let cellCount = span.text.count * span.cellWidth
        let origin = metrics.origin(row: row, column: span.column)
        if let background {
            let rect = CGRect(
                x: origin.x,
                y: origin.y,
                width: CGFloat(cellCount) * metrics.cellWidth,
                height: metrics.lineHeight
            )
            context.fill(Path(rect), with: .color(background))
        }
        var attributes = AttributeContainer()
        attributes.font = metrics.font(bold: style.bold, italic: style.italic)
        attributes.foregroundColor = style.faint ? foreground.opacity(0.6) : foreground
        if style.underline { attributes.underlineStyle = .single }
        if style.strikethrough { attributes.strikethroughStyle = .single }
        if span.cellWidth == 1 {
            let text = Text(AttributedString(span.text, attributes: attributes))
            context.draw(context.resolve(text), at: origin, anchor: .topLeading)
        } else {
            // Wide glyphs: place each character at its own cell offset so the
            // grid stays aligned regardless of the font's natural advance.
            for (index, character) in span.text.enumerated() {
                let text = Text(AttributedString(String(character), attributes: attributes))
                let characterOrigin = CGPoint(
                    x: origin.x + CGFloat(index * span.cellWidth) * metrics.cellWidth,
                    y: origin.y
                )
                context.draw(context.resolve(text), at: characterOrigin, anchor: .topLeading)
            }
        }
    }

    private func cursorRect(metrics: HiveTerminalGridMetrics) -> CGRect? {
        guard let cursor = grid.cursor, cursor.visible,
              cursor.row >= 0, cursor.row < grid.rows,
              cursor.column >= 0, cursor.column < grid.columns else { return nil }
        let origin = metrics.origin(row: cursor.row, column: cursor.column)
        switch cursor.style {
        case .bar:
            return CGRect(x: origin.x, y: origin.y, width: 2, height: metrics.lineHeight)
        case .underline:
            return CGRect(
                x: origin.x,
                y: origin.y + metrics.lineHeight - 2,
                width: metrics.cellWidth,
                height: 2
            )
        case .block, .blockHollow:
            return CGRect(x: origin.x, y: origin.y, width: metrics.cellWidth, height: metrics.lineHeight)
        }
    }

    private var cursorColor: Color {
        HiveTerminalColor.parse(grid.terminalCursorColor)
            ?? HiveTerminalColor.parse(grid.terminalForeground)
            ?? HiveTerminalColor.fallbackForeground
    }

    /// Filled cursor shapes paint underneath the glyphs so the character under
    /// a block cursor stays readable.
    private func drawCursorBackground(in context: inout GraphicsContext, metrics: HiveTerminalGridMetrics) {
        guard let rect = cursorRect(metrics: metrics), grid.cursor?.style != .blockHollow else { return }
        context.fill(Path(rect), with: .color(cursorColor.opacity(0.55)))
    }

    private func drawCursorOutline(in context: inout GraphicsContext, metrics: HiveTerminalGridMetrics) {
        guard let rect = cursorRect(metrics: metrics), grid.cursor?.style == .blockHollow else { return }
        context.stroke(Path(rect), with: .color(cursorColor), lineWidth: 1)
    }
}

/// Cell geometry: fits the remote grid's columns × rows into the available
/// size by scaling one monospaced font.
struct HiveTerminalGridMetrics {
    let cellWidth: CGFloat
    let lineHeight: CGFloat
    let fontSize: CGFloat

    init(columns: Int, rows: Int, available: CGSize) {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        // Measure the reference font once; monospaced advances scale linearly
        // with point size, so one measurement fits any target size.
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
