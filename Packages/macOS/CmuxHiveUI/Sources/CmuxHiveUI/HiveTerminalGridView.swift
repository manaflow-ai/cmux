public import CmuxHive
import CMUXMobileCore
import AppKit
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
    @State private var cachedMetrics: HiveTerminalGridMetricsCache?

    /// Creates a grid view over one immutable grid snapshot.
    public init(grid: HiveTerminalGridModel) {
        self.grid = grid
    }

    public var body: some View {
        Canvas { context, size in
            let metrics: HiveTerminalGridMetrics
            if let cachedMetrics,
               cachedMetrics.matches(columns: grid.columns, rows: grid.rows, available: size) {
                metrics = cachedMetrics.metrics
            } else {
                metrics = HiveTerminalGridMetrics(
                    columns: grid.columns,
                    rows: grid.rows,
                    available: size
                )
            }
            draw(in: &context, metrics: metrics)
        }
        .background(HiveTerminalColor.parse(grid.terminalBackground) ?? HiveTerminalColor.fallbackBackground)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            cachedMetrics = HiveTerminalGridMetricsCache(
                columns: grid.columns,
                rows: grid.rows,
                available: size,
                metrics: HiveTerminalGridMetrics(
                    columns: grid.columns,
                    rows: grid.rows,
                    available: size
                )
            )
        }
        .onChange(of: grid.columns) { _, _ in cachedMetrics = nil }
        .onChange(of: grid.rows) { _, _ in cachedMetrics = nil }
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
        let origin = metrics.origin(row: row, column: span.column)
        if let background {
            let rect = CGRect(
                x: origin.x,
                y: origin.y,
                width: CGFloat(span.totalCellWidth) * metrics.cellWidth,
                height: metrics.lineHeight
            )
            context.fill(Path(rect), with: .color(background))
        }
        if style.invisible { return }
        var attributes = AttributeContainer()
        attributes.font = metrics.font(bold: style.bold, italic: style.italic)
        attributes.foregroundColor = style.faint ? foreground.opacity(0.6) : foreground
        if style.underline { attributes.underlineStyle = .single }
        if style.strikethrough { attributes.strikethroughStyle = .single }
        if span.isUniformSingleWidth {
            let text = Text(AttributedString(span.text, attributes: attributes))
            context.draw(context.resolve(text), at: origin, anchor: .topLeading)
        } else {
            // Mixed widths (wide glyphs / combining marks): place each
            // character at its own cell offset, advancing by that character's
            // grid width, so alignment matches the remote terminal.
            var cellOffset = 0
            for character in span.text {
                let text = Text(AttributedString(String(character), attributes: attributes))
                let characterOrigin = CGPoint(
                    x: origin.x + CGFloat(cellOffset) * metrics.cellWidth,
                    y: origin.y
                )
                context.draw(context.resolve(text), at: characterOrigin, anchor: .topLeading)
                cellOffset += character.renderGridEstimatedCellWidth
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
