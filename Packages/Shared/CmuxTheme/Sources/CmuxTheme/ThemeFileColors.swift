import Foundation

/// One Ghostty theme file's colors (Resources/ghostty/themes, `~/.config/ghostty/themes`):
/// `background`, `foreground`, `palette = N=#rrggbb`, `selection-*` and `cursor-*`. The same
/// reading as the web module's `parseGhosttyTheme` (`webviews/src/theme/ghosttyTheme.ts`), so the
/// Settings page's preview and the app agree on a theme's colors.
///
/// ```swift
/// let colors = ThemeFileColors(name: "Nord", themeFile: text)
/// let app = colors.map { AppTheme.derive(background: $0.background, foreground: $0.foreground, palette: $0.palette) }
/// ```
public struct ThemeFileColors: Hashable, Sendable {
    public let name: String
    public let background: ThemeRGB
    public let foreground: ThemeRGB
    /// ANSI 0...15; nil where the file sets no color.
    public let palette: [ThemeRGB?]
    public let selectionBackground: ThemeRGB?
    public let selectionForeground: ThemeRGB?
    public let cursorColor: ThemeRGB?
    public let cursorText: ThemeRGB?

    /// The colors of a theme file's text; nil when it names no background and foreground.
    public init?(name: String, themeFile text: String) {
        var values: [String: ThemeRGB] = [:]
        var palette = [ThemeRGB?](repeating: nil, count: 16)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "palette" {
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let index = Int(parts[0]), (0..<16).contains(index),
                      let color = Self.sixDigit(parts[1]) else { continue }
                palette[index] = color
            } else if let color = Self.sixDigit(value) {
                values[key] = color
            }
        }
        guard let background = values["background"], let foreground = values["foreground"] else { return nil }
        self.name = name
        self.background = background
        self.foreground = foreground
        self.palette = palette
        selectionBackground = values["selection-background"]
        selectionForeground = values["selection-foreground"]
        cursorColor = values["cursor-color"]
        cursorText = values["cursor-text"]
    }

    /// The app theme of these colors.
    public var appTheme: AppTheme { AppTheme.derive(background: background, foreground: foreground, palette: palette) }

    /// `#rrggbb` or `rrggbb` only, as the web parser accepts.
    private static func sixDigit(_ text: String) -> ThemeRGB? {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return ThemeRGB(cssHex: digits)
    }
}
