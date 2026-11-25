/// `appearance.wallpaperLighting`: treats the desktop wallpaper as a light source, so glass edges
/// facing its brightest part catch its color, the composer glows with it, and the glass leans toward
/// its hue. Off unless set to true.
public struct WallpaperLightingSetting: Sendable {
    /// Creates the setting parser.
    public init() {}

    /// Parses a bool, treating an absent value as off.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Bool {
        guard let value = root.value(at: Self.configPath) else { return Self.fallback }
        guard let enabled = value.boolValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.wallpaperLighting",
                                                  message: "expected true or false"))
            return Self.fallback
        }
        return enabled
    }
}
