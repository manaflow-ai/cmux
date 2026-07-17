import CMUXMobileCore
import SwiftUI

/// Exposé-style miniature of a terminal surface, drawn from a styled
/// render-grid snapshot: span backgrounds as rects, span text as tiny
/// monospaced runs in their real colors. Unreadable by design — the point is
/// the SHAPE of the content (a stack trace, a TUI, a quiet prompt).
struct TerminalGridMiniatureView: View {
    let frame: MobileTerminalRenderGridFrame

    var body: some View {
        Canvas { context, size in
            let columns = max(frame.columns, 1)
            let rows = max(frame.rows, 1)
            let cellWidth = size.width / CGFloat(columns)
            let rowHeight = size.height / CGFloat(rows)
            let stylesByID = Dictionary(
                uniqueKeysWithValues: frame.styles.map { ($0.id, $0) }
            )
            let fallbackForeground = Self.color(frame.terminalForeground) ?? .white
            let font = Font.system(size: max(rowHeight * 0.82, 1.5), design: .monospaced)

            for span in frame.rowSpans {
                guard span.row >= 0, span.row < rows else { continue }
                let style = stylesByID[span.styleID]
                let origin = CGPoint(
                    x: CGFloat(span.column) * cellWidth,
                    y: CGFloat(span.row) * rowHeight
                )
                let inverse = style?.inverse == true
                let backgroundHex = inverse ? style?.foreground : style?.background
                if let background = Self.color(backgroundHex) {
                    let width = CGFloat(span.cellWidth ?? span.text.count) * cellWidth
                    context.fill(
                        Path(CGRect(x: origin.x, y: origin.y, width: width, height: rowHeight)),
                        with: .color(background)
                    )
                }
                guard !span.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let foregroundHex = inverse ? style?.background : style?.foreground
                let foreground = Self.color(foregroundHex) ?? fallbackForeground
                var text = Text(span.text).font(font)
                text = text.foregroundColor(foreground.opacity(style?.faint == true ? 0.55 : 0.92))
                context.draw(
                    context.resolve(text),
                    at: CGPoint(x: origin.x, y: origin.y + rowHeight / 2),
                    anchor: .leading
                )
            }
        }
        .background(Self.color(frame.terminalBackground) ?? .black)
        .clipped()
        .accessibilityHidden(true)
    }

    private static func color(_ hex: String?) -> Color? {
        guard let hex, let rgb = TerminalTheme.rgbComponents(hex) else { return nil }
        return Color(
            red: Double(rgb.red) / 255.0,
            green: Double(rgb.green) / 255.0,
            blue: Double(rgb.blue) / 255.0
        )
    }
}
