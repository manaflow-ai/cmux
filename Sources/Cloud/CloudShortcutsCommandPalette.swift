import AppKit
import CmuxCloud
import CmuxCommandPalette

/// Command palette entries for the Cloud teaching shortcuts. Each one runs the
/// same entrypoint as its shortcut (``AppDelegate/handleCloudTeachingShortcut(_:)``),
/// so the palette, the Cloud menu, the "What can I do here?" popover and the
/// key all behave the same.
extension ContentView {
    static let commandPaletteCloudSecretsCommandId = "palette.cloud.secrets"
    static let commandPaletteCloudToggleSidebarCommandId = "palette.cloud.toggleSidebar"
    static let commandPaletteCloudHelpCommandId = "palette.cloud.help"

    /// The palette shortcut hint for a Cloud teaching command, if it has one.
    static func commandPaletteCloudTeachingShortcutAction(forCommandID commandId: String) -> KeyboardShortcutSettings.Action? {
        switch commandId {
        case commandPaletteCloudSecretsCommandId: return .openCloudSecrets
        case commandPaletteCloudToggleSidebarCommandId: return .toggleCloudPanel
        case commandPaletteCloudOpenRepositoryCommandId: return .openRepositoryInCloud
        default: return nil
        }
    }

    static func commandPaletteCloudTeachingContributions(
        isAuthenticated: Bool? = nil
    ) -> [CommandPaletteCommandContribution] {
        guard CloudMachinesFeature.isEnabled else { return [] }
        let subtitle: (CommandPaletteContextSnapshot) -> String = { _ in
            String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud")
        }
        var contributions = [
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudToggleSidebarCommandId,
                title: { _ in String(localized: "command.cloud.toggleSidebar.title", defaultValue: "Toggle Cloud Sidebar") },
                subtitle: subtitle,
                keywords: ["cloud", "sidebar", "machines", "panel", "show", "hide", "toggle"]
            ),
        ]
        guard isAuthenticated ?? (AppDelegate.shared?.auth?.accountFlow.isAuthenticated == true) else { return contributions }
        contributions += [
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudSecretsCommandId,
                title: { _ in String(localized: "cloudSecrets.menu.app", defaultValue: "Cloud Secrets\u{2026}") },
                subtitle: subtitle,
                keywords: ["cloud", "secrets", "keys", "api", "token", "env", "environment", "vault"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudHelpCommandId,
                title: { _ in String(localized: "command.cloud.help.title", defaultValue: "What Can I Do in Cloud?") },
                subtitle: subtitle,
                keywords: ["cloud", "help", "shortcuts", "cli", "actions", "learn", "tips"]
            ),
        ]
        return contributions
    }

    func registerCloudTeachingCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        let commandWindow = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        registry.register(commandId: Self.commandPaletteCloudToggleSidebarCommandId) {
            if AppDelegate.shared?.toggleCloudPanel(preferredWindow: commandWindow, debugSource: "palette.cloud.toggleSidebar") != true {
                NSSound.beep()
            }
        }
        registry.register(commandId: Self.commandPaletteCloudSecretsCommandId) {
            if AppDelegate.shared?.openCloudSecrets(preferredWindow: commandWindow, debugSource: "palette.cloud.secrets") != true {
                NSSound.beep()
            }
        }
        registry.register(commandId: Self.commandPaletteCloudHelpCommandId) {
            if AppDelegate.shared?.showCloudTeachingHelp(preferredWindow: commandWindow, debugSource: "palette.cloud.help") != true {
                NSSound.beep()
            }
        }
    }
}
