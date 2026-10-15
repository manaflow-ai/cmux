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

    /// The values of the last load of the user's config (tests set it).
    public static var loaded = GhosttyConfigBackground()

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
