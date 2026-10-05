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
/// does not load the page again. Keyboard goes to the Keyboard Shortcuts page. With no main
/// window the request waits for one: a closed window comes back (or a new one opens) and the
/// first window that mounts a pane opens the tab (`windowDidShowContent`, called by
/// `WorkspaceContentController`).
@MainActor
final class SettingsWindowService: InternalPageProvider {
    unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// The window whose tab shows Settings, if any.
    var window: NSWindow? {
        services.pages.window(showing: .settings, windows: services.windows.controllers)?.window
    }

    /// The kept React page (a reopen shows it again with no reload); nil before the first show.
    private var webPage: PageWebView?
    /// The route the next page view opens on.
    private var pendingRoute: String?
    /// A show that waits for a main window with a workspace.
    private var waiting: (section: SettingsSection?, setting: String?, focus: Bool)?
    var isWaiting: Bool { waiting != nil }
    /// The page fragment the Settings page shows, or will open with.
    var currentRoute: String? { webPage?.route ?? pendingRoute }

    /// Shows Settings on `section`, or on `setting` (a cmux.json key path, card or button
    /// `SettingsAnchor(key:)` knows) with its highlight. An unknown setting is refused and opens
    /// nothing. `focus` false (automation) opens the tab without selecting it.
    func show(section: SettingsSection?, setting: String? = nil, focus: Bool = true) throws {
        guard services.settings != nil else { throw ActionFailure(message: RefusalStrings.settingsNotLoaded) }
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
        guard let windows = services.windows, let window = windows.active, Self.hasPane(window) else {
            waiting = (target, setting, focus)
            if let windows = services.windows, windows.restored, windows.controllers.isEmpty { windows.reopenOrCreateWindow() }
            return
        }
        waiting = nil
        let route = Self.route(section: target, setting: setting)
        pendingRoute = route
        let view = services.pages.show(.settings, in: window, focus: focus)
        if let route, let page = view?.content as? PageWebView, page.route != route { page.open(route: route) }
    }

    /// A window installed its workspace content or mounted a pane: a show that waited for a window
    /// with a pane runs now.
    func windowDidShowContent() {
        guard let request = waiting, let window = services.windows?.active, Self.hasPane(window) else { return }
        waiting = nil
        try? show(section: request.section, setting: request.setting, focus: request.focus)
    }

    private static func hasPane(_ window: WindowController) -> Bool {
        window.content.map { !$0.panes.isEmpty } ?? false
    }

    /// The page fragment for `section` and `setting`: a schema setting focuses its row; any other
    /// anchor opens its section.
    static func route(section: SettingsSection?, setting: String?) -> String? {
        if let setting, let descriptor = SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: setting)) {
            return "#/settings/\(descriptor.section.rawValue)?focus=\(descriptor.id)"
        }
        return section.map { "#/settings/\($0.rawValue)" }
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .settings }
    var title: String { SettingsDeepLink.pageTitle }
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
        // A live preview left by a closed page (mid-drag) must not stay applied.
        services.settings?.endPreview()
    }

    // MARK: Host facts (the page's host lists)

    var rooms: [SettingsListRow]? {
        let local = services.machines.local
        guard local.supports(DaemonCapabilities.shared.profiles) else { return nil }
        let current = services.windows.active?.state.profileID ?? .defaultProfile
        return local.store.profiles.sorted { $0.index < $1.index }.map { room in
            SettingsListRow.space(id: room.id.rawValue, title: room.name, icon: room.icon, isActive: room.id == current)
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

    /// The Ghostty config file the terminals read (the first file
    /// libghostty loaded), else the default location.
    var ghosttyConfigPath: String {
        if let loaded = GhosttyRuntime.shared.loadedConfigFiles.first {
            return (loaded as NSString).abbreviatingWithTildeInPath
        }
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

    var browserProfiles: [SettingsBrowserProfileRow] {
        services.browserProfiles.ordered.map { record in
            SettingsBrowserProfileRow(id: record.id, name: record.name, color: record.color, icon: record.icon,
                                      isDefault: record.isDefault, source: record.source?["display_name"])
        }
    }
}
