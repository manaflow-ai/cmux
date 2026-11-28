import Foundation

/// A terminal color theme: the base background/foreground/cursor/selection
/// colors plus the ANSI palette.
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
    /// Ghostty bold-color behavior (`bright` or `#rrggbb`), or `nil` when unset.
    public var boldColor: String?
    /// Cursor color (`#rrggbb`).
    public var cursor: String
    /// Cell-relative cursor-color semantics, when configured.
    public var cursorColorSemantic: CellRelativeColor?
    /// Cursor text color (`#rrggbb`), or `nil` to let the terminal derive one.
    public var cursorText: String?
    /// Cell-relative cursor-text semantics, when configured.
    public var cursorTextSemantic: CellRelativeColor?
    /// Selection background color (`#rrggbb`).
    public var selectionBackground: String
    /// Cell-relative selection-background semantics, when configured.
    public var selectionBackgroundSemantic: CellRelativeColor?
    /// Selection foreground color (`#rrggbb`).
    public var selectionForeground: String
    /// Cell-relative selection-foreground semantics, when configured.
    public var selectionForegroundSemantic: CellRelativeColor?
    /// The ANSI palette, either its 16-color base or all 256 entries.
    ///
    /// Indices 0-7 are the normal colors and 8-15 are the bright variants, in
    /// the standard order: black, red, green, yellow, blue, magenta, cyan, white.
    public var palette: [String]
    /// Ghostty settings outside the color slots that still change how those
    /// colors render, read from the machine that runs the terminal session.
    /// `nil` when the host predates this field; the phone then renders with
    /// Ghostty's defaults rather than any phone-local setting.
    public var rendering: Rendering?

    /// Ghostty settings that change how theme colors render on screen.
    ///
    /// Each field mirrors one Ghostty config key. A `nil` field means the host
    /// did not report it, and the phone uses Ghostty's default for that key.
    public struct Rendering: Codable, Equatable, Sendable {
        /// `minimum-contrast`, 1 to 21.
        public var minimumContrast: Double?
        /// `faint-opacity`, 0 to 1.
        public var faintOpacity: Double?
        /// `cursor-opacity`, 0 to 1.
        public var cursorOpacity: Double?
        /// `palette-generate`.
        public var paletteGenerate: Bool?
        /// `palette-harmonious`.
        public var paletteHarmonious: Bool?
        /// `alpha-blending`: `native`, `linear` or `linear-corrected`.
        public var alphaBlending: String?
        /// `window-colorspace`: `srgb` or `display-p3`.
        public var windowColorspace: String?

        /// Values Ghostty accepts for `alpha-blending`.
        public static let alphaBlendingValues: Set<String> = ["native", "linear", "linear-corrected"]
        /// Values Ghostty accepts for `window-colorspace`.
        public static let windowColorspaceValues: Set<String> = ["srgb", "display-p3"]

        public init(
            minimumContrast: Double? = nil,
            faintOpacity: Double? = nil,
            cursorOpacity: Double? = nil,
            paletteGenerate: Bool? = nil,
            paletteHarmonious: Bool? = nil,
            alphaBlending: String? = nil,
            windowColorspace: String? = nil
        ) {
            self.minimumContrast = minimumContrast
            self.faintOpacity = faintOpacity
            self.cursorOpacity = cursorOpacity
            self.paletteGenerate = paletteGenerate
            self.paletteHarmonious = paletteHarmonious
            self.alphaBlending = alphaBlending
            self.windowColorspace = windowColorspace
        }

        /// The Ghostty directives for every field that holds a value Ghostty
        /// accepts. Out-of-range or unknown values are dropped, so the key
        /// keeps Ghostty's default.
        public var ghosttyDirectives: [String] {
            var lines: [String] = []
            if let value = minimumContrast, value.isFinite, (1...21).contains(value) {
                lines.append("minimum-contrast = \(value)")
            }
            if let value = faintOpacity, value.isFinite, (0...1).contains(value) {
                lines.append("faint-opacity = \(value)")
            }
            if let value = cursorOpacity, value.isFinite, (0...1).contains(value) {
                lines.append("cursor-opacity = \(value)")
            }
            if let paletteGenerate {
                lines.append("palette-generate = \(paletteGenerate)")
            }
            if let paletteHarmonious {
                lines.append("palette-harmonious = \(paletteHarmonious)")
            }
            if let value = alphaBlending, Self.alphaBlendingValues.contains(value) {
                lines.append("alpha-blending = \(value)")
            }
            if let value = windowColorspace, Self.windowColorspaceValues.contains(value) {
                lines.append("window-colorspace = \(value)")
            }
            return lines
        }
    }

    /// Ghostty directives that return every key a theme can set to Ghostty's
    /// default. Load these before ``ghosttyColorDirectives`` so a value the
    /// host did not send falls back to Ghostty's default, never to a setting
    /// left in the phone's own config (a stale `theme =`, palette entries past
    /// the ones the host sent, or a rendering key).
    public static let ghosttyResetDirectives: String = [
        "theme =",
        "palette =",
        "bold-color =",
        "cursor-color =",
        "cursor-text =",
        "selection-background =",
        "selection-foreground =",
        "minimum-contrast =",
        "faint-opacity =",
        "cursor-opacity =",
        "palette-generate =",
        "palette-harmonious =",
        "alpha-blending =",
        "window-colorspace =",
    ].joined(separator: "\n")

    /// The number of palette entries a valid theme must carry.
    public static let paletteCount = 16
    /// The number of entries in a complete Ghostty palette snapshot.
    public static let extendedPaletteCount = 256

    public init(
        background: String,
        foreground: String,
        boldColor: String? = nil,
        cursor: String,
        cursorColorSemantic: CellRelativeColor? = nil,
        cursorText: String? = nil,
        cursorTextSemantic: CellRelativeColor? = nil,
        selectionBackground: String,
        selectionBackgroundSemantic: CellRelativeColor? = nil,
        selectionForeground: String,
        selectionForegroundSemantic: CellRelativeColor? = nil,
        palette: [String],
        rendering: Rendering? = nil
    ) {
        self.background = background
        self.foreground = foreground
        self.boldColor = boldColor
        self.cursor = cursor
        self.cursorColorSemantic = cursorColorSemantic
        self.cursorText = cursorText
        self.cursorTextSemantic = cursorTextSemantic
        self.selectionBackground = selectionBackground
        self.selectionBackgroundSemantic = selectionBackgroundSemantic
        self.selectionForeground = selectionForeground
        self.selectionForegroundSemantic = selectionForegroundSemantic
        self.palette = palette
        self.rendering = rendering
    }

    /// Whether every color string parses and the palette has exactly 16 entries.
    public var isValid: Bool {
        guard palette.count == Self.paletteCount || palette.count == Self.extendedPaletteCount else { return false }
        if let boldColor,
           boldColor.lowercased() != "bright",
           Self.rgbComponents(boldColor) == nil {
            return false
        }
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
        if let boldColor {
            if boldColor.lowercased() == "bright" {
                lines.append("bold-color = bright")
            } else if let color = Self.canonicalHex(boldColor) {
                lines.append("bold-color = \(color)")
            }
        }
        if let cursorColorSemantic {
            lines.append("cursor-color = \(cursorColorSemantic.rawValue)")
        } else if let cur = Self.canonicalHex(cursor) {
            lines.append("cursor-color = \(cur)")
        }
        if let cursorTextSemantic {
            lines.append("cursor-text = \(cursorTextSemantic.rawValue)")
        } else if let cursorText, let curText = Self.canonicalHex(cursorText) {
            lines.append("cursor-text = \(curText)")
        }
        if let selectionBackgroundSemantic {
            lines.append("selection-background = \(selectionBackgroundSemantic.rawValue)")
        } else if let selBg = Self.canonicalHex(selectionBackground) {
            lines.append("selection-background = \(selBg)")
        }
        if let selectionForegroundSemantic {
            lines.append("selection-foreground = \(selectionForegroundSemantic.rawValue)")
        } else if let selFg = Self.canonicalHex(selectionForeground) {
            lines.append("selection-foreground = \(selFg)")
        }
        for (index, color) in palette.enumerated() {
            if let hex = Self.canonicalHex(color) {
                lines.append("palette = \(index)=\(hex)")
            }
        }
        if let rendering {
            lines.append(contentsOf: rendering.ghosttyDirectives)
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
