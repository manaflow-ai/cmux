public import CmuxNextDesign

/// The Ghostty config files' own `background-opacity` and `background-blur`,
/// before cmux.json's window background (`GhosttyRuntime.backgroundOverride`)
/// replaces them: the values Settings' Material "Ghostty" stands for.
///
/// ```swift
/// let ghostty = GhosttyConfigBackground.loaded
/// override.resolved(backgroundOpacity: ghostty.opacity, backgroundBlur: ghostty.blur)
/// ```
public struct GhosttyConfigBackground {
    /// `background-opacity`, 0...1.
    public var opacity: Double
    /// `background-blur` in Ghostty's C encoding (0 off, > 0 radius, -1/-2 macOS glass).
    public var blur: Int

    public init(opacity: Double = 1, blur: Int = 0) {
        self.opacity = opacity
        self.blur = blur
    }

    /// The values of the last load of the user's config. Every load of it records them again, so a test passes
    /// its own values to their reader (`TerminalThemeSetting.ghostty`) instead of setting these.
    public static var loaded = GhosttyConfigBackground()

    /// `override` over these values: the opacity and blur the window and the surfaces use.
    public func resolved(_ override: WindowBackgroundOverride) -> (backgroundOpacity: Double, backgroundBlur: Int) {
        override.resolved(backgroundOpacity: opacity, backgroundBlur: blur)
    }

    /// Whether a change of cmux.json's window background from `old` to `new` needs the terminals' config reload at
    /// once: the window turns translucent or opaque (the surfaces' default background changes) or its material changes.
    public func surfacesChange(from old: WindowBackgroundOverride, to new: WindowBackgroundOverride) -> Bool {
        let (before, after) = (resolved(old), resolved(new))
        return (before.backgroundOpacity >= 1) != (after.backgroundOpacity >= 1)
            || WindowMaterialChoice(ghosttyBlur: before.backgroundBlur) != WindowMaterialChoice(ghosttyBlur: after.backgroundBlur)
    }

    /// The lines that put cmux.json's window background over a config load's
    /// values; a load of the user's own config (no `theme`) also records them.
    static func overrideLines(configuredOpacity: Double, configuredBlur: Int, theme: String?) -> [String] {
        if theme == nil {
            loaded = GhosttyConfigBackground(opacity: configuredOpacity, blur: configuredBlur)
            GhosttyConfigFontFamily.recordLoad()
        }
        return GhosttyRuntime.backgroundOverrideLines(GhosttyRuntime.backgroundOverride,
                                                      configuredOpacity: configuredOpacity, configuredBlur: configuredBlur)
    }
}
