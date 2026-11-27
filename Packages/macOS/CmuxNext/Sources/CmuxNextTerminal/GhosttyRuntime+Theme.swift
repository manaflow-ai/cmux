import CmuxNextDesign
import GhosttyNextKit

/// The theme colors of the applied Ghostty config, as 8-bit sRGB values.
/// The App turns this into CmuxNextDesign's `ThemeInput` (this module does
/// not depend on Design).
public nonisolated struct GhosttyThemeColors: Hashable, Sendable {
    public struct RGB: Hashable, Sendable {
        public var r: UInt8
        public var g: UInt8
        public var b: UInt8
    }

    public var background: RGB
    public var foreground: RGB
    /// ANSI palette 0...15.
    public var palette: [RGB]
    /// Only when the config sets a plain color. Ghostty does not expose
    /// `cell-foreground`/`cell-background` selection values through its C
    /// API; those read as nil.
    public var selectionBackground: RGB?
    public var selectionForeground: RGB?
    /// `cursor-color`, only when the config sets a plain color.
    public var cursor: RGB?
    public var backgroundOpacity: Double
    /// Ghostty's encoding: 0 off, >0 blur radius, -1/-2 macOS glass.
    public var backgroundBlur: Int
}

extension GhosttyRuntime {
    /// The theme `themeOverride` names for the current color scheme (a pair's variant); nil while
    /// the Ghostty config's own theme applies, which has no name.
    public static var themeName: String? {
        themeOverride.flatMap(ThemeSpec.init).map { $0.name(isDark: colorSchemeIsDark) }
    }

    /// Colors of the config currently applied to every surface. Nil when
    /// libghostty failed to load a config.
    public var themeColors: GhosttyThemeColors? {
        guard let config else { return nil }
        return Self.themeColors(of: config, backgroundOpacity: backgroundOpacity)
    }

    static func themeColors(of config: ghostty_config_t, backgroundOpacity: Double) -> GhosttyThemeColors? {
        guard let background = Self.color(config, "background"), let foreground = Self.color(config, "foreground") else {
            return nil
        }
        var palette = ghostty_config_palette_s()
        let paletteColors: [GhosttyThemeColors.RGB] = Self.configGet(config, &palette, key: "palette")
            ? withUnsafeBytes(of: &palette.colors) { raw in
                raw.bindMemory(to: ghostty_config_color_s.self).prefix(16).map { GhosttyThemeColors.RGB(r: $0.r, g: $0.g, b: $0.b) }
            }
            : []
        var blur: Int16 = 0
        _ = Self.configGet(config, &blur, key: "background-blur")
        return GhosttyThemeColors(
            background: background,
            foreground: foreground,
            palette: paletteColors,
            selectionBackground: Self.color(config, "selection-background"),
            selectionForeground: Self.color(config, "selection-foreground"),
            cursor: Self.color(config, "cursor-color"),
            backgroundOpacity: backgroundOpacity,
            backgroundBlur: Int(blur)
        )
    }

    /// The colors of a config made of `text` (Ghostty config lines), for tests.
    static func themeColors(configText text: String) -> GhosttyThemeColors? {
        _ = shared // runs ghostty_init, which config_new needs
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        return themeColors(of: config, backgroundOpacity: 1)
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> GhosttyThemeColors.RGB? {
        var color = ghostty_config_color_s()
        guard configGet(config, &color, key: key) else { return nil }
        return GhosttyThemeColors.RGB(r: color.r, g: color.g, b: color.b)
    }
}

// MARK: The iPhone's terminal theme

extension GhosttyRuntime {
    /// The Ghostty keys of the terminal theme the iPhone takes from this Mac. hostd keeps only
    /// these (`cmux-mobile-host` `appearance.rs` `TERMINAL_KEYS`) and the phone resets and loads
    /// these (`CmuxMobileTerminalTheme.keys`); keep the three lists the same.
    public nonisolated static let phoneTerminalThemeKeys: Set<String> = [
        "background", "foreground", "palette",
        "cursor-color", "cursor-text", "cursor-opacity",
        "selection-background", "selection-foreground", "bold-color",
        "minimum-contrast", "faint-opacity", "palette-generate", "palette-harmonious",
        "alpha-blending", "window-colorspace",
        "search-background", "search-foreground", "search-selected-background", "search-selected-foreground",
    ]

    /// The terminal theme of the config applied to every surface, as Ghostty config lines
    /// (`key = value`, one per palette entry), for the iPhone: what this Mac's terminals show, with
    /// the light or dark variant now applied and all 256 palette entries. A key whose value the C
    /// API cannot read (unset, a cell-relative cursor or selection color, `bold-color`) goes empty,
    /// so the phone resets it to Ghostty's default. Empty when libghostty has no config.
    public var phoneTerminalThemeLines: [String] {
        guard let config else { return [] }
        return Self.phoneTerminalThemeLines(of: config)
    }

    static func phoneTerminalThemeLines(of config: ghostty_config_t) -> [String] {
        func hex(_ color: GhosttyThemeColors.RGB) -> String { String(format: "#%02x%02x%02x", color.r, color.g, color.b) }
        guard let background = color(config, "background"), let foreground = color(config, "foreground") else { return [] }
        var lines = ["background = \(hex(background))", "foreground = \(hex(foreground))"]
        var palette = ghostty_config_palette_s()
        if configGet(config, &palette, key: "palette") {
            withUnsafeBytes(of: &palette.colors) { raw in
                for (index, entry) in raw.bindMemory(to: ghostty_config_color_s.self).enumerated() {
                    lines.append("palette = \(index)=\(hex(GhosttyThemeColors.RGB(r: entry.r, g: entry.g, b: entry.b)))")
                }
            }
        }
        for key in ["cursor-color", "cursor-text", "selection-background", "selection-foreground", "bold-color",
                    "search-background", "search-foreground", "search-selected-background", "search-selected-foreground"] {
            lines.append(color(config, key).map { "\(key) = \(hex($0))" } ?? "\(key) =")
        }
        for key in ["cursor-opacity", "minimum-contrast", "faint-opacity"] {
            var value: Double = 0
            lines.append(configGet(config, &value, key: key) && value.isFinite ? "\(key) = \(value)" : "\(key) =")
        }
        for key in ["palette-generate", "palette-harmonious"] {
            var value = false
            lines.append(configGet(config, &value, key: key) ? "\(key) = \(value)" : "\(key) =")
        }
        for key in ["alpha-blending", "window-colorspace"] {
            var value: UnsafePointer<CChar>?
            lines.append(configGet(config, &value, key: key) ? value.map { "\(key) = \(String(cString: $0))" } ?? "\(key) =" : "\(key) =")
        }
        return lines
    }

    /// The iPhone terminal theme lines of a config made of `text`, for tests.
    static func phoneTerminalThemeLines(configText text: String) -> [String] {
        _ = shared // runs ghostty_init, which config_new needs
        guard let config = ghostty_config_new() else { return [] }
        defer { ghostty_config_free(config) }
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        return phoneTerminalThemeLines(of: config)
    }
}
