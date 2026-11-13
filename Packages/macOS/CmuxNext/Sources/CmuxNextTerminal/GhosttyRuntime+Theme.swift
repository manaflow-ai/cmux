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
    /// (`key = value`, one per palette entry), for the iPhone. Ghostty writes them itself
    /// (`ghostty_config_serialize`, every effective value), so they hold what this Mac's terminals
    /// show: the light or dark variant now applied, `bold-color = bright`, cell-relative cursor and
    /// selection colors, all 256 palette entries. Empty when libghostty has no config.
    public var phoneTerminalThemeLines: [String] {
        guard let config else { return [] }
        return Self.phoneTerminalThemeLines(of: config)
    }

    static func phoneTerminalThemeLines(of config: ghostty_config_t) -> [String] {
        let serialized = ghostty_config_serialize(config)
        defer { ghostty_string_free(serialized) }
        guard let pointer = serialized.ptr, serialized.len > 0 else { return [] }
        let text = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(serialized.len)), as: UTF8.self)
        return phoneTerminalThemeLines(serialized: text)
    }

    /// The lines of `text` (a serialized Ghostty config) whose key is a terminal theme key.
    nonisolated static func phoneTerminalThemeLines(serialized text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard phoneTerminalThemeKeys.contains(key) else { return nil }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? "\(key) =" : "\(key) = \(value)"
        }
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
