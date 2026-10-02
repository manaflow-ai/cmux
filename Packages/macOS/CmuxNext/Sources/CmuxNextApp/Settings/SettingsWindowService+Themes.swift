import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettingsWindow

/// The Settings theme picker acts on the window Settings was opened from
/// (the active main window) and runs the same theme actions as the palette,
/// context menus and CLI.
extension SettingsWindowService {
    var themeLevels: [SettingsThemeLevel] {
        guard services.windows.active != nil else { return [] }
        let personal = services.machines.local.supports(DaemonCapabilities.shared.profiles)
        return (personal ? [.room, .workspace] : []) + [.terminal]
    }

    var themeNames: [String] { services.themes.catalog.names }

    func theme(at level: SettingsThemeLevel) -> String? {
        let current = services.themes.currentChoice(Self.action(level, reset: false), target: nil)
        return current == ActionArgument.themeConfigValue ? nil : current
    }

    func acceptsTheme(_ text: String) -> Bool { services.themes.catalog.accepts(text) }

    func setTheme(_ spec: String?, at level: SettingsThemeLevel) {
        let id = Self.action(level, reset: spec == nil)
        let arguments: [String: ActionValue] = spec.map { ["theme": .string($0)] } ?? [:]
        services.registry.perform(id, invocation: ActionInvocation(arguments: arguments))
    }

    private static func action(_ level: SettingsThemeLevel, reset: Bool) -> ActionID {
        switch level {
        case .room: reset ? "space.clearTheme" : "space.setTheme"
        case .workspace: reset ? "workspace.clearTheme" : "workspace.setTheme"
        case .terminal: reset ? "terminal.clearTheme" : "terminal.setTheme"
        }
    }
}
