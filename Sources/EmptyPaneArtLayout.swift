import AppKit

/// Sizes empty-pane art so every line fits on one row inside the space
/// available, never above the terminal font size.
///
/// Measures the monospaced cell at a reference size and scales the font
/// linearly, so the art shrinks as a whole instead of wrapping or clipping.
struct EmptyPaneArtLayout {
    /// Below this the art is unreadable anyway; it is only reached by art far
    /// wider than any pane.
    static let minimumFontSize: CGFloat = 1
    private static let referenceFontSize: CGFloat = 100
    /// Headroom for rounding between AppKit's measurement and SwiftUI's
    /// text layout.
    private static let fitSlack: CGFloat = 0.97

    let font: NSFont
    let boldFont: NSFont
    /// One character cell at `font`.
    let cellSize: CGSize
    /// The whole art: columns x lines of cells.
    let size: CGSize

    init(fontFamily: String, columns: Int, lines: Int, preferredFontSize: CGFloat, maxSize: CGSize) {
        let reference = Self.font(family: fontFamily, size: Self.referenceFontSize)
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: reference]).width / Self.referenceFontSize
        let lineHeight = NSLayoutManager().defaultLineHeight(for: reference) / Self.referenceFontSize
        let columns = CGFloat(max(columns, 1))
        let lines = CGFloat(max(lines, 1))
        let fitting = min(
            max(maxSize.width, 0) / (columns * cellWidth),
            max(maxSize.height, 0) / (lines * lineHeight)
        ) * Self.fitSlack
        let fontSize = max(Self.minimumFontSize, min(preferredFontSize, fitting))
        font = Self.font(family: fontFamily, size: fontSize)
        boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        cellSize = CGSize(width: cellWidth * fontSize, height: lineHeight * fontSize)
        size = CGSize(width: ceil(columns * cellSize.width), height: ceil(lines * cellSize.height))
    }

    /// The terminal font family at `size`, or the system monospaced font when
    /// the family is not installed.
    static func font(family: String, size: CGFloat) -> NSFont {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont(name: family, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
