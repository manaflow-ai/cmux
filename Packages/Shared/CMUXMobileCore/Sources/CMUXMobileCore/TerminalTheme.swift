import Foundation

/// A terminal color theme: the base background/foreground/cursor/selection
/// colors plus the 16-entry ANSI palette.
///
/// This is the canonical theme value the mobile terminal renders with. It is a
/// pure value type (no UIKit/AppKit) so it lives in `CMUXMobileCore` and can be
/// produced on the Mac, transported over the wire, and consumed by the embedded
/// libghostty runtime on iOS. Colors are stored as `#rrggbb` hex strings, the
/// same wire shape libghostty's config and the render-grid `Style` colors use.
///
/// Use ``monokai`` as the built-in default when no theme has been supplied.
public struct TerminalTheme: Codable, Equatable, Sendable {
    /// Terminal background color (`#rrggbb`).
    public var background: String
    /// Terminal foreground color (`#rrggbb`).
    public var foreground: String
    /// Cursor color (`#rrggbb`).
    public var cursor: String
    /// Cursor text color (`#rrggbb`), or `nil` to let the terminal derive one.
    public var cursorText: String?
    /// Selection background color (`#rrggbb`).
    public var selectionBackground: String
    /// Selection foreground color (`#rrggbb`).
    public var selectionForeground: String
    /// The 16-color ANSI palette, indices `0...15`, low to high.
    ///
    /// Indices 0-7 are the normal colors and 8-15 are the bright variants, in
    /// the standard order: black, red, green, yellow, blue, magenta, cyan, white.
    public var palette: [String]

    /// The number of palette entries a valid theme must carry.
    public static let paletteCount = 16

    public init(
        background: String,
        foreground: String,
        cursor: String,
        cursorText: String? = nil,
        selectionBackground: String,
        selectionForeground: String,
        palette: [String]
    ) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }

    /// Whether every color string parses and the palette has exactly 16 entries.
    public var isValid: Bool {
        guard palette.count == Self.paletteCount else { return false }
        var colors = [background, foreground, cursor, selectionBackground, selectionForeground]
        colors.append(contentsOf: palette)
        if let cursorText { colors.append(cursorText) }
        return colors.allSatisfy { Self.rgbComponents($0) != nil }
    }

    /// Parses a `#rrggbb` (or `rrggbb`) hex string into 0-255 RGB components,
    /// or `nil` when the string is not a valid 6-digit hex color.
    public static func rgbComponents(_ value: String?) -> (red: Int, green: Int, blue: Int)? {
        guard var value else { return nil }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let raw = Int(value, radix: 16) else { return nil }
        return ((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
    }

    /// Normalizes a hex color to canonical `#rrggbb` form, or `nil` when it does
    /// not parse. `rgbComponents` accepts a bare `rrggbb`, so this re-emits the
    /// `#`-prefixed form the theme contract (and ghostty directives) expect.
    static func canonicalHex(_ value: String?) -> String? {
        guard let rgb = rgbComponents(value) else { return nil }
        return String(format: "#%02x%02x%02x", rgb.red, rgb.green, rgb.blue)
    }

    /// The ghostty config directives that express this theme's colors, one per
    /// line. Suitable for appending to an iOS ghostty config file.
    ///
    /// Only colors that parse are emitted, so a partially-invalid theme still
    /// produces a usable (if incomplete) config rather than corrupt directives.
    public var ghosttyColorDirectives: String {
        var lines: [String] = []
        if let bg = Self.canonicalHex(background) { lines.append("background = \(bg)") }
        if let fg = Self.canonicalHex(foreground) { lines.append("foreground = \(fg)") }
        if let cur = Self.canonicalHex(cursor) { lines.append("cursor-color = \(cur)") }
        if let cursorText, let curText = Self.canonicalHex(cursorText) {
            lines.append("cursor-text = \(curText)")
        }
        if let selBg = Self.canonicalHex(selectionBackground) {
            lines.append("selection-background = \(selBg)")
        }
        if let selFg = Self.canonicalHex(selectionForeground) {
            lines.append("selection-foreground = \(selFg)")
        }
        for (index, color) in palette.enumerated() {
            if let hex = Self.canonicalHex(color) {
                lines.append("palette = \(index)=\(hex)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Returns this theme if it validates, otherwise ``monokai``. Use this to
    /// resolve an untrusted or partially-decoded theme to a renderable one.
    public func validatedOrDefault() -> TerminalTheme {
        isValid ? self : .monokai
    }

    /// The built-in Monokai theme, used as the default when no theme is supplied.
    public static let monokai = TerminalTheme(
        background: "#272822",
        foreground: "#fdfff1",
        cursor: "#c0c1b5",
        cursorText: nil,
        selectionBackground: "#57584f",
        selectionForeground: "#fdfff1",
        palette: [
            "#272822", // 0  black
            "#f92672", // 1  red
            "#a6e22e", // 2  green
            "#e6db74", // 3  yellow
            "#fd971f", // 4  blue
            "#ae81ff", // 5  magenta
            "#66d9ef", // 6  cyan
            "#fdfff1", // 7  white
            "#6e7066", // 8  bright black
            "#f92672", // 9  bright red
            "#a6e22e", // 10 bright green
            "#e6db74", // 11 bright yellow
            "#fd971f", // 12 bright blue
            "#ae81ff", // 13 bright magenta
            "#66d9ef", // 14 bright cyan
            "#fdfff1", // 15 bright white
        ]
    )
}
