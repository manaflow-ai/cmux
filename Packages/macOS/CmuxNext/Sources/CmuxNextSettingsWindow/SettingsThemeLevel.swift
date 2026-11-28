/// Where the Settings theme picker applies a theme, for the window Settings was opened from (the
/// page labels each level from `settingsWindow.themeLevel.*`).
public enum SettingsThemeLevel: String, CaseIterable, Identifiable, Sendable {
    case room, workspace, terminal

    public var id: String { rawValue }
}
