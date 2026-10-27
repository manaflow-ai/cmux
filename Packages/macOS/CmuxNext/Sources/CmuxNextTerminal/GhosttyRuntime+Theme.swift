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
        // SAFETY: the runtime's live applied config (GhosttyRuntime.config).
        return unsafe Self.themeColors(of: config, backgroundOpacity: backgroundOpacity)
    }

    /// The colors of `config`, a live handle the caller holds for the call.
    static func themeColors(of config: ghostty_config_t, backgroundOpacity: Double) -> GhosttyThemeColors? {
        // SAFETY: the caller's live config.
        guard let background = unsafe Self.color(config, "background"), let foreground = unsafe Self.color(config, "foreground") else {
            return nil
        }
        var palette = ghostty_config_palette_s()
        // SAFETY: the caller's live config; palette is a ghostty_config_palette_s, whose `colors`
        // is a C array of 256 ghostty_config_color_s, so its bytes bind to that type and the
        // first 16 are in bounds.
        let paletteColors: [GhosttyThemeColors.RGB] = unsafe Self.configGet(config, &palette, key: "palette")
            ? withUnsafeBytes(of: &palette.colors) { raw in
                // SAFETY: as above.
                unsafe raw.bindMemory(to: ghostty_config_color_s.self).prefix(16).map { GhosttyThemeColors.RGB(r: $0.r, g: $0.g, b: $0.b) }
            }
            : []
        var blur: Int16 = 0
        // SAFETY: the caller's live config; background-blur is an int16_t.
        _ = unsafe Self.configGet(config, &blur, key: "background-blur")
        // SAFETY: the caller's live config.
        return unsafe GhosttyThemeColors(
            background: background,
            foreground: foreground,
            palette: paletteColors,
            selectionBackground: Self.color(config, "selection-background"),
            selectionForeground: Self.color(config, "selection-foreground"),
            cursor: Self.color(config, "cursor-color"),
            backgroundOpacity: backgroundOpacity,
            backgroundBlur: Int(truncatingIfNeeded: blur)
        )
    }

    /// The colors of a config made of `text` (Ghostty config lines), for tests.
    static func themeColors(configText text: String) -> GhosttyThemeColors? {
        _ = shared // runs ghostty_init, which config_new needs
        // SAFETY: withScratchConfig's handle is live for each closure's call and stays in it.
        let colors = unsafe withScratchConfig(load: { unsafe loadConfigLine(text, into: $0, source: "test") },
                                              read: { unsafe themeColors(of: $0, backgroundOpacity: 1) })
        return colors ?? nil
    }

    /// A color key of `config`, a live handle the caller holds for the call.
    private static func color(_ config: ghostty_config_t, _ key: String) -> GhosttyThemeColors.RGB? {
        var color = ghostty_config_color_s()
        // SAFETY: the caller's live config; the caller names color keys only.
        guard unsafe configGet(config, &color, key: key) else { return nil }
        return GhosttyThemeColors.RGB(r: color.r, g: color.g, b: color.b)
    }
}
