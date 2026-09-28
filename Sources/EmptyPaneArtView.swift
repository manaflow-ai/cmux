import AppKit
import CmuxFoundation
import SwiftUI

/// The user's `emptyPane.artFile` art, drawn on a character-cell grid in the
/// terminal font and palette and shrunk to fit `maxSize` without wrapping.
///
/// Backgrounds and block elements (▀ ▄ █ quadrants, as `chafa` emits) are
/// filled as pixel-aligned cell rectangles, the way a terminal draws them, so
/// block art has no seams between rows. Other characters are drawn as text
/// runs starting at their cell.
struct EmptyPaneArtView: View {
    /// Parsed art plus the terminal appearance it renders with.
    struct Content: Equatable {
        let art: ANSIArt
        let palette: ANSIArtPalette
        let fontFamily: String
        let preferredFontSize: CGFloat
    }

    let content: Content
    let maxSize: CGSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let layout = EmptyPaneArtLayout(
            fontFamily: content.fontFamily,
            columns: content.art.columnCount,
            lines: content.art.lines.count,
            preferredFontSize: content.preferredFontSize,
            maxSize: maxSize
        )
        Canvas { context, _ in
            draw(in: &context, layout: layout)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .allowsHitTesting(false)
        // Decorative: VoiceOver hears the same title the default view shows.
        .accessibilityElement()
        .accessibilityLabel(String(localized: "emptyPanel.title", defaultValue: "Empty Panel"))
        .accessibilityIdentifier("EmptyPanelArt")
    }

    private func draw(in context: inout GraphicsContext, layout: EmptyPaneArtLayout) {
        let palette = content.palette
        for (row, line) in content.art.lines.enumerated() {
            var column = 0
            for run in line.runs {
                let colors = palette.resolvedColors(for: run.style)
                let dimming = run.style.isDim ? 0.5 : 1
                let foreground = Self.color(colors.foreground, opacity: dimming)
                let cells = Array(run.text.unicodeScalars)
                if let background = colors.background {
                    context.fill(
                        Path(cellRect(
                            column: column,
                            row: row,
                            width: cells.reduce(0) { $0 + ANSIArt.cellWidth(of: $1) },
                            layout: layout
                        )),
                        with: .color(Self.color(background, opacity: 1))
                    )
                }
                // Text is drawn in segments that start on their cell.
                // Characters the terminal font covers at one cell share a
                // segment; a wide character or one drawn from a fallback font
                // gets its own, so the rest of the line stays on the grid.
                // Combining marks stay with the character before them.
                var textStart = column
                var text = String.UnicodeScalarView()
                var segmentIsIsolated = false
                func flushText() {
                    defer {
                        text = String.UnicodeScalarView()
                        segmentIsIsolated = false
                    }
                    guard !String(text).allSatisfy(\.isWhitespace) else { return }
                    let font = run.style.isBold ? layout.boldFont : layout.font
                    context.draw(
                        Text(String(text)).font(Font(font as CTFont)).foregroundStyle(foreground),
                        at: CGPoint(x: CGFloat(textStart) * layout.cellSize.width, y: CGFloat(row) * layout.cellSize.height),
                        anchor: .topLeading
                    )
                }
                for scalar in cells {
                    let width = ANSIArt.cellWidth(of: scalar)
                    if let block = ANSIArtBlockElement(scalar) {
                        flushText()
                        let cell = cellRect(column: column, row: row, width: 1, layout: layout)
                        for unit in block.rects {
                            let rect = snapped(CGRect(
                                x: cell.minX + unit.minX * cell.width,
                                y: cell.minY + unit.minY * cell.height,
                                width: unit.width * cell.width,
                                height: unit.height * cell.height
                            ))
                            context.fill(Path(rect), with: .color(Self.color(colors.foreground, opacity: block.opacity * dimming)))
                        }
                        column += 1
                        continue
                    }
                    let needsOwnSegment = width > 1 || (width == 1 && !layout.coveredCharacters.contains(scalar))
                    if width > 0, segmentIsIsolated || needsOwnSegment {
                        flushText()
                    }
                    if text.isEmpty {
                        textStart = column
                    }
                    if needsOwnSegment {
                        segmentIsIsolated = true
                    }
                    text.append(scalar)
                    column += width
                }
                flushText()
            }
        }
    }

    /// The pixel-aligned rect of `width` cells, so neighboring cells share
    /// edges exactly and fills leave no hairlines.
    private func cellRect(column: Int, row: Int, width: Int, layout: EmptyPaneArtLayout) -> CGRect {
        snapped(CGRect(
            x: CGFloat(column) * layout.cellSize.width,
            y: CGFloat(row) * layout.cellSize.height,
            width: CGFloat(width) * layout.cellSize.width,
            height: layout.cellSize.height
        ))
    }

    private func snapped(_ rect: CGRect) -> CGRect {
        let scale = max(displayScale, 1)
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func color(_ rgb: ANSIArtRGB, opacity: Double) -> Color {
        Color(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255,
            opacity: opacity
        )
    }
}
