/// `appearance.liveWallpaperFrameRate`: the most frames per second a live wallpaper draws
/// (plans/cmux-next/live-wallpapers.md, "Settings"): "15", "30" (the default) or "60". The
/// wallpaper's own `fps` may ask for fewer; the scheduler takes the lower of the two
/// (`cmux_wallpaper_schedule`).
public struct LiveWallpaperFrameRateSetting: Sendable {
    /// Creates the setting parser.
    public init() {}

    /// Parses one of ``values`` into frames per second, treating an absent value as the default
    /// and a wrong one as the default with a diagnostic.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Int {
        let fallback = Int(Self.fallback) ?? 30
        guard let value = root.value(at: Self.configPath) else { return fallback }
        guard let text = value.stringValue, Self.values.contains(text), let fps = Int(text) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.liveWallpaperFrameRate",
                                                  message: "expected \"15\", \"30\" or \"60\""))
            return fallback
        }
        return fps
    }
}
