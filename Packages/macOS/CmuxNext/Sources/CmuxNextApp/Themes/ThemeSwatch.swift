import CmuxNextDesign
import Foundation

/// A theme's swatch strip for the theme pickers (R98): its background, ANSI
/// red, green, yellow, blue, magenta and cyan, then its foreground, read
/// from the Ghostty theme file. `ThemeCatalog` reads every theme file once,
/// off the main thread, and keeps the strips.
nonisolated enum ThemeSwatch {
    /// The ANSI entries a strip shows, in order.
    static let paletteIndices = [1, 2, 3, 4, 5, 6]

    /// The strip in a Ghostty theme file's text; empty when it sets no color.
    static func strip(themeFile text: String) -> [ThemeRGB] {
        []
    }
}
