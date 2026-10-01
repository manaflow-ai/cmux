import Foundation

/// Where the Settings theme picker applies a theme, for the window Settings
/// was opened from.
public enum SettingsThemeLevel: String, CaseIterable, Identifiable, Sendable {
    case room, workspace, terminal

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .room: SettingsWindowStrings.themeLevelRoom
        case .workspace: SettingsWindowStrings.themeLevelWorkspace
        case .terminal: SettingsWindowStrings.themeLevelTerminal
        }
    }
}
