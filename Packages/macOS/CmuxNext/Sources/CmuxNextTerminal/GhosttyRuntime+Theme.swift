import GhosttyKit

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
    public var backgroundOpacity: Double
    /// Ghostty's encoding: 0 off, >0 blur radius, -1/-2 macOS glass.
    public var backgroundBlur: Int
}

extension GhosttyRuntime {
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
            backgroundOpacity: backgroundOpacity,
            backgroundBlur: Int(blur)
        )
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> GhosttyThemeColors.RGB? {
        var color = ghostty_config_color_s()
        guard configGet(config, &color, key: key) else { return nil }
        return GhosttyThemeColors.RGB(r: color.r, g: color.g, b: color.b)
    }
}
