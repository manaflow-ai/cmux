import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextTerminal
import Foundation

/// Owns Settings (Settings…, Cmd-, and the app menu) and feeds it the live
/// state cmux.json does not hold: rooms of the local daemon, saved
/// machines, the Ghostty config and the shortcut writer. Settings opens as
/// an internal page tab in the active window (`InternalPageTabStore`), or
/// as its own window under the Debug Settings choice
/// `settings.presentation = window` or when no main window can hold the
/// tab. One model serves every tab and the window; it is made on first
/// show and dropped once nothing shows it.
@MainActor
final class SettingsWindowService: SettingsWindowHost, InternalPageProvider {
    unowned let services: AppServices
    private var controller: SettingsWindowController?
    private var sharedModel: SettingsWindowModel?

    init(services: AppServices) {
        self.services = services
    }

    /// The open model, and the window that shows Settings: its own window,
    /// else the main window with a Settings tab (debug and tests).
    var model: SettingsWindowModel? { sharedModel }
    var window: NSWindow? {
        controller?.window ?? services.pages.window(showing: .settings, windows: services.windows.controllers)?.window
    }

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
        let model = sharedModel ?? SettingsWindowModel(settings: settings, registry: services.registry, host: self)
        sharedModel = model
        if SettingsWindowLayout.presentation.value == .pane, let window = services.windows.active {
            if let anchor {
                model.open(anchor)
            } else if let section {
                model.select(section, layout: SettingsWindowLayout.tunable.value)
            }
            // Settings draws in the theme of the window that shows it.
            SettingsPane.follow(window.themeScope)
            if services.pages.show(.settings, in: window, focus: services.viewChangeAllowed) != nil { return }
        }
        if controller == nil {
            let controller = SettingsWindowController(model: model)
            controller.onClose = { [weak self] in
                self?.controller = nil
                self?.dropModelWhenUnused()
            }
            self.controller = controller
        }
        controller?.setThemeScope(services.windows.active?.themeScope ?? .app)
        controller?.present(section: section, anchor: anchor)
    }

    /// A key while a shortcut recording runs in a Settings tab: the
    /// recorder takes it before any shortcut (a recorded Cmd-W must not
    /// close the tab). The Settings window routes its own keys.
    func handlePaneRecorderKey(_ event: NSEvent) -> Bool {
        guard controller == nil, let model = sharedModel, model.recorder != nil, event.type == .keyDown,
              !services.pages.keys(of: .settings).isEmpty else { return false }
        return model.handleRecorderKey(event)
    }

    private func dropModelWhenUnused() {
        guard controller == nil, services.pages.keys(of: .settings).isEmpty else { return }
        sharedModel?.cancelRecording()
        sharedModel = nil
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .settings }
    var title: String { SettingsPane.title }
    var symbol: String { "gearshape" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let model = sharedModel ?? services.settings.map { SettingsWindowModel(settings: $0, registry: services.registry, host: self) }
        sharedModel = model
        guard let model else { return NSView() }
        return SettingsPane.makeView(model: model, scope: window?.themeScope ?? .app)
    }

    func tabClosed(_ key: String) {
        dropModelWhenUnused()
    }

    // MARK: SettingsWindowHost

    var systemWideRefusals: Set<ActionID> { services.globalHotKeys.conflicts }

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
