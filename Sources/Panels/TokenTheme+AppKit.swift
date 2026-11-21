import AppKit
import CmuxSyntaxHighlighting

extension TokenTheme {
    /// Resolves token colors from the view appearance and Ghostty palette.
    init(
        appearance: NSAppearance?,
        terminalPalette: [Int: NSColor] = [:],
        terminalForegroundColor: NSColor? = nil
    ) {
        let resolved = appearance?.bestMatch(from: [.darkAqua, .aqua]) ?? NSAppearance.Name.aqua
        let base = resolved == .darkAqua ? TokenTheme.dark : TokenTheme.light
        guard !terminalPalette.isEmpty else {
            self = base
            return
        }

        let ansiPalette = terminalPalette.reduce(into: [Int: TokenColor]()) { result, entry in
            if let color = Self.tokenColor(from: entry.value) {
                result[entry.key] = color
            }
        }
        let foreground = terminalForegroundColor.flatMap(Self.tokenColor(from:))
            ?? base.palette.foreground
        self = TokenTheme(
            base: base,
            palette: TokenPalette(
                ansiPalette: ansiPalette,
                foreground: foreground,
                fallback: base.palette
            )
        )
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

    private static func tokenColor(from color: NSColor) -> TokenColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return TokenColor(
            red: UInt8((rgb.redComponent * 255).rounded()),
            green: UInt8((rgb.greenComponent * 255).rounded()),
            blue: UInt8((rgb.blueComponent * 255).rounded())
        )
    }
}
