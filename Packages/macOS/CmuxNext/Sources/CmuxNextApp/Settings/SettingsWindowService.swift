import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextTerminal
import Foundation

/// Owns Settings (Settings…, Cmd-, the app menu, the palette, `settings.open`). R82: Settings is
/// the React page (cmux-page://cmux.settings/, `SettingsPageProvider`), opened as an internal
/// page tab in the active window. One page view is kept and shown again on reopen, so a reopen
/// does not load the page again. Keyboard goes to the Keyboard Shortcuts page.
///
/// INTERIM (R82 B): the sections the React page does not draw yet (accounts, rooms, machines),
/// and Settings with no main window open, still open the Swift Settings window with its model.
/// That path goes when those sections reach the page.
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

    /// The kept React page (a reopen shows it again with no reload); nil before the first show.
    private var webPage: PageWebView?
    /// The route the next page view opens on.
    private var pendingRoute: String?

    /// Sections only the Swift window draws (R82 B, interim).
    static let swiftSections: Set<SettingsSection> = [.accounts, .rooms, .machines]

    /// Shows Settings on `section`, or on `setting` (a cmux.json key path, card or button
    /// `SettingsAnchor(key:)` knows) with its highlight. An unknown setting is refused and opens
    /// nothing. `focus` false (automation) opens the tab without selecting it.
    func show(section: SettingsSection?, setting: String? = nil, focus: Bool = true) throws {
        guard let settings = services.settings else { throw ActionFailure(message: RefusalStrings.settingsNotLoaded) }
        var anchor: SettingsAnchor?
        if let setting {
            guard let found = SettingsAnchor(key: setting) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noSuchSettingsEntry(setting))
            }
            anchor = found
        }
        let target = anchor?.section ?? section
        if target == .keyboard {
            let invocation = ActionInvocation(origin: focus ? .user : .cli)
            guard services.registry.perform("keybindings.open", invocation: invocation) else {
                throw ActionFailure(message: RefusalStrings.noWindowOpen)
            }
            return
        }
        if let target, Self.swiftSections.contains(target) {
            return showWindow(settings: settings, section: section, anchor: anchor)
        }
        let route = Self.route(section: target, setting: setting)
        guard let window = services.windows.active else {
            return showWindow(settings: settings, section: section, anchor: anchor)
        }
        pendingRoute = route
        let view = services.pages.show(.settings, in: window, focus: focus)
        if let route, let page = view?.content as? PageWebView, page.route != route { page.open(route: route) }
    }

    /// The page fragment for `section` and `setting`: a schema setting focuses its row; any other
    /// anchor opens its section.
    static func route(section: SettingsSection?, setting: String?) -> String? {
        if let setting, let descriptor = SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: setting)) {
            return "#/settings/\(descriptor.section.rawValue)?focus=\(descriptor.id)"
        }
        return section.map { "#/settings/\($0.rawValue)" }
    }

    /// The Swift Settings window (interim, R82 B).
    private func showWindow(settings: SettingsController, section: SettingsSection?, anchor: SettingsAnchor?) {
        let model = sharedModel ?? SettingsWindowModel(settings: settings, registry: services.registry, host: self)
        sharedModel = model
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

    private func dropModelWhenUnused() {
        guard controller == nil else { return }
        sharedModel?.cancelRecording()
        sharedModel = nil
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .settings }
    var title: String { SettingsWindowModel.paneTitle }
    var symbol: String { "gearshape" }

    /// The kept page when no other tab shows it, else a new one (a second window's tab).
    func makeView(for key: String, in window: WindowController?) -> NSView {
        let route = pendingRoute
        pendingRoute = nil
        if let webPage, webPage.superview == nil {
            if let route, webPage.route != route { webPage.open(route: route) }
            return webPage
        }
        guard let page = PageFactory(services: services).settingsPage(route: route) else { return NSView() }
        if webPage == nil { webPage = page }
        return page
    }

    func tabClosed(_ key: String) {
        dropModelWhenUnused()
    }

    // MARK: SettingsWindowHost

    var systemWideRefusals: Set<ActionID> { services.globalHotKeys.conflicts }

    /// Escape in the focused Settings page closes that page tab. Cmd-W uses
    /// the shared close-tab action path, so both gestures remove the same
    /// internal page and leave no popup behind.
    func closeSettingsPane() {
        guard let pane = services.windows.active?.focusedPane,
              let selected = pane.stripModel.selectedID,
              LocalPageTab.page(of: selected.rawValue) == .settings else { return }
        pane.close([selected])
    }

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
