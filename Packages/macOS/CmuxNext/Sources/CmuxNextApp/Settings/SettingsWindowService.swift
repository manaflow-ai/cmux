import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextTerminal
import Foundation

/// Owns the Settings window (Settings…, Cmd-, and the app menu) and feeds
/// it the live state cmux.json does not hold: rooms of the local daemon,
/// saved machines, the Ghostty config and the shortcut writer. The window
/// is created on first show and released when it closes.
@MainActor
final class SettingsWindowService: SettingsWindowHost {
    unowned let services: AppServices
    private var controller: SettingsWindowController?

    init(services: AppServices) {
        self.services = services
    }

    /// The open window's model and window (debug and tests).
    var model: SettingsWindowModel? { controller?.model }
    var window: NSWindow? { controller?.window }

    /// Shows Settings on `section`, or scrolled to `setting` (a cmux.json
    /// key path, card or button `SettingsAnchor(key:)` knows) with its
    /// highlight. An unknown setting is refused and opens nothing.
    func show(section: SettingsSection?, setting: String? = nil) throws {
        guard let settings = services.settings else { throw ActionFailure(message: RefusalStrings.settingsNotLoaded) }
        var anchor: SettingsAnchor?
        if let setting {
            guard let found = SettingsAnchor(key: setting) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noSuchSettingsEntry(setting))
            }
            anchor = found
        }
        if controller == nil {
            let controller = SettingsWindowController(model: SettingsWindowModel(settings: settings, registry: services.registry, host: self))
            controller.onClose = { [weak self] in self?.controller = nil }
            self.controller = controller
        }
        // Settings draws in the theme of the window it was opened from.
        controller?.setThemeScope(services.windows.active?.themeScope ?? .app)
        controller?.present(section: section, anchor: anchor)
    }

    // MARK: SettingsWindowHost

    var rooms: [SettingsListRow]? {
        let local = services.machines.local
        guard local.supports(DaemonCapabilities.shared.profiles) else { return nil }
        let current = services.windows.active?.state.profileID ?? .defaultProfile
        return local.store.profiles.sorted { $0.index < $1.index }.map { room in
            SettingsListRow(id: room.id.rawValue, title: room.name, subtitle: nil,
                            symbol: room.icon ?? "square.stack", isActive: room.id == current)
        }
    }

    var machines: [SettingsListRow] {
        let ssh = services.machines.ssh.map { session in
            SettingsListRow(id: session.machineID, title: session.host.label, subtitle: session.host.destination.description,
                            symbol: "server.rack", isActive: Self.isConnected(session.daemon.store.connectionState))
        }
        let cloud = services.machines.cloud.map { session in
            SettingsListRow(id: session.machineID, title: session.machine.title, subtitle: nil,
                            symbol: "cloud", isActive: Self.isConnected(session.daemon.store.connectionState))
        }
        return ssh + cloud
    }

    private static func isConnected(_ state: DaemonConnectionState) -> Bool {
        if case .connected = state { true } else { false }
    }

    var ghosttyConfigPath: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.config"
        return base + "/ghostty/config"
    }

    var shellIntegration: String? { GhosttyRuntime.shared.shellIntegrationSettings?.mode }

    /// The window opacity the theme resolved (Ghostty's, or the default a
    /// chosen material gets), so the unset slider sits where the window is:
    /// read through the active window's theme scope (the app scope when no
    /// window is open), which inherits the app theme unless a room
    /// overrides it.
    func derivedNumber(at path: [String]) -> Double? {
        path == WindowBackgroundSetting.opacityPath ? (services.windows.active?.themeScope ?? ThemeScope.app).input.backgroundOpacity : nil
    }

    var shortcutEditor: (any ShortcutRecorderEditing)? { services.paletteShortcutEditor }

    var browserProfiles: [SettingsBrowserProfileRow] {
        services.browserProfiles.ordered.map { record in
            SettingsBrowserProfileRow(id: record.id, name: record.name, color: record.color, icon: record.icon,
                                      isDefault: record.isDefault, source: record.source?["display_name"])
        }
    }
}
