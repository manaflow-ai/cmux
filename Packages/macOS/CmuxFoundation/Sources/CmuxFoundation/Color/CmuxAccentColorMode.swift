public import Foundation

/// Which color cmux-drawn chrome uses as its accent (`app.accentColor`).
public enum CmuxAccentColorMode: String, CaseIterable, Sendable {
    /// cmux's own blue, the same in every macOS accent setting.
    case cmux
    /// The macOS accent color from System Settings > Appearance.
    case system

    /// UserDefaults key storing the raw value.
    public static let userDefaultsKey = "appAccentColor"

    /// Mode used when nothing valid is stored.
    public static let defaultValue: CmuxAccentColorMode = .cmux

    /// Reads the stored mode, falling back to ``defaultValue`` for a missing
    /// or unrecognized value. Reads the key directly so drawing code can call
    /// it without building the settings catalog.
    public static func stored(in defaults: UserDefaults = .standard) -> CmuxAccentColorMode {
        CmuxAccentColorMode(rawValue: defaults.string(forKey: userDefaultsKey) ?? "") ?? defaultValue
    }
}
