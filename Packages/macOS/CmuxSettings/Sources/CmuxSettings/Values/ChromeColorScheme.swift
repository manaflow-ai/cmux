/// The two concrete variants a chrome theme can provide.
public enum ChromeColorScheme: String, CaseIterable, Sendable, SettingCodable {
    /// The light variant of a built-in chrome theme.
    case light
    /// The dark variant of a built-in chrome theme.
    case dark
}
