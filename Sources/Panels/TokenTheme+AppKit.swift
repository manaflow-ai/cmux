import AppKit
import CmuxSyntaxHighlighting

extension TokenTheme {
    /// Resolves light/dark token palettes from the view's effective appearance.
    init(appearance: NSAppearance?) {
        let resolved = appearance?.bestMatch(from: [.darkAqua, .aqua]) ?? NSAppearance.Name.aqua
        self = resolved == .darkAqua ? .dark : .light
    }

    /// Product-blue wash behind the caret line.
    var currentLineFillColor: NSColor {
        nsColor(palette.currentLine, alpha: palette.currentLineAlpha)
    }

    /// Cool muted indent-guide stroke.
    var indentGuideColor: NSColor {
        nsColor(palette.indentGuide, alpha: palette.indentGuideAlpha)
    }

    /// Caret-line gutter numeral. Product blue.
    var gutterCurrentLineColor: NSColor {
        nsColor(palette.keyword, alpha: 1)
    }

    /// Other gutter numerals. Brand muted.
    var gutterDefaultColor: NSColor {
        nsColor(palette.comment, alpha: 1)
    }

    private func nsColor(_ color: TokenColor, alpha: Double) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255.0,
            green: CGFloat(color.green) / 255.0,
            blue: CGFloat(color.blue) / 255.0,
            alpha: alpha
        )
    }
}
