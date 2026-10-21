/// `appearance.wallpaperTint`: where the desktop shows through the window, its tint takes the
/// desktop picture's hue and follows it to a new picture or Space (``WallpaperTint``). On unless
/// set to false.
public struct WallpaperTintSetting: Sendable {
    /// The shared Settings and cmux.json path.
    public let configPath = ["appearance", "wallpaperTint"]
    /// The value when the key is absent or invalid.
    public static let fallback = true

    /// Creates the setting parser.
    public init() {}

    /// Parses a bool, treating an absent value as on.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Bool {
        guard let value = root.value(at: configPath) else { return Self.fallback }
        guard let enabled = value.boolValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.wallpaperTint",
                                                  message: "expected true or false"))
            return Self.fallback
        }
        return enabled
    }
}
