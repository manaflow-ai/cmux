/// `appearance.liveWallpaperGrade`: how much the tritone grade tones a live wallpaper, 0 (the
/// default: its own colors) to 1 (plans/cmux-next/live-wallpapers.md, "Settings"). The grade runs
/// in the host's half of every program (cmux-wallpaper's `epilogue.wgsl`, `Frame.grade`), so every
/// first-party and third-party wallpaper gets it.
public struct LiveWallpaperGradeSetting: Sendable {
    /// Creates the setting parser.
    public init() {}

    /// Parses a number in ``range``, treating an absent value as the default and a wrong one as the
    /// default with a diagnostic.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: Self.configPath) else { return Self.fallback }
        guard let number = value.doubleValue, Self.range.contains(number) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.liveWallpaperGrade",
                                                  message: "expected a number from 0 to 1, such as 0.5"))
            return Self.fallback
        }
        return number
    }
}
