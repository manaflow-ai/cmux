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
        var background: ThemeRGB?
        var foreground: ThemeRGB?
        var palette: [Int: ThemeRGB] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "background": background = ThemeRGB(cssHex: value)
            case "foreground": foreground = ThemeRGB(cssHex: value)
            case "palette":
                let entry = value.split(separator: "=", maxSplits: 1)
                guard entry.count == 2, let index = Int(entry[0].trimmingCharacters(in: .whitespaces)),
                      let color = ThemeRGB(cssHex: String(entry[1])) else { continue }
                palette[index] = color
            default: continue
            }
        }
        return [background].compactMap(\.self) + paletteIndices.compactMap { palette[$0] } + [foreground].compactMap(\.self)
    }
}
