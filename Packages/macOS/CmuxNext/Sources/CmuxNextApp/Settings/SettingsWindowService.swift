import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextIcons
import CmuxNextPages
import CmuxNextServer
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextTerminal
import CmuxNextWakeups
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

    /// The applied Ghostty config's diagnostics the Settings page lists (R92), made at the first page read and
    /// kept current from then on.
    private(set) lazy var ghosttyDiagnostics = GhosttyDiagnosticsModel(mainWork: services.mainWork, work: services.work)

    /// The window whose tab shows Settings, if any.
    var window: NSWindow? {
        services.pages.window(showing: .settings, windows: services.windows.controllers)?.window
    }

    /// One Settings page and the forms it reports unsaved.
    private struct Page {
        let view: PageWebView
        let edits: SettingsPageProvider.Edits
    }

    /// The kept React page (a reopen shows it again with no reload); nil before the first show and
    /// after its tab's view was discarded.
    private var webPage: Page?
    /// The page each tab shows (the kept page or a second window's own), by tab key.
    private var tabPages: [String: Page] = [:]
    /// The route each show asked for, for the page view of the tab it opened or selected.
    private let opens = PageOpenRequests<String>()
    /// A show that waits for a main window with a workspace.
    private var waiting: (section: SettingsSection?, setting: String?, focus: Bool, route: String?)?
    var isWaiting: Bool { waiting != nil }

    /// Shows Settings on `section`, or on `setting` (a cmux.json key path, card or button
    /// `SettingsAnchor(key:)` knows) with its highlight. An unknown setting is refused and opens
    /// nothing. `focus` false (automation) opens the tab without selecting it.
    /// `route` opens a page-only place instead (`#/settings/agents?focus=agents.add`, Settings >
    /// Agents' Add panel), with no section or setting.
    func show(section: SettingsSection?, setting: String? = nil, focus: Bool = true, route pageRoute: String? = nil) throws {
        guard services.settings != nil else { throw ActionFailure(message: RefusalStrings.settingsNotLoaded) }
        // task-owner: one read of the device list per opening (Settings > Devices); the directory's runs go off main.
        services.work.task(.userVisible) { [devices = services.devices] in await devices.refresh() }
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
        let route = pageRoute ?? Self.route(section: target, setting: setting)
        // The window's one Settings tab comes back when another workspace of the window holds it
        // (nxdog77: Cmd-, in a second workspace opened a second Settings tab).
        if focus, let window = services.windows.active { revealSettingsTab(of: window) }
        // A user run in a window whose workspace has no pane to hold a tab (an empty workspace,
        // or Home standing for the home workspace) shows Settings as the window's top page
        // (nxdog70: Cmd-, on Home with an empty workspace showed nothing).
        if focus, let window = services.windows.active, !Self.holdsTab(window, services) {
            waiting = nil
            showTopPage(in: window, route: route)
            return
        }
        guard case let windows = services.windows, let window = windows.active, Self.hasPane(window) else {
            waiting = (target, setting, focus, pageRoute)
            if case let windows = services.windows, windows.restored, windows.controllers.isEmpty { windows.reopenOrCreateWindow() }
            return
        }
        waiting = nil
        let view = opens.open(route) { services.pages.show(.settings, in: window, focus: focus) }
        // A shown page moves to the route; a tab with no page yet opens on it at its first show.
        if let route, let view, view.isBuilt, let page = view.content as? PageWebView, page.route != route { page.open(route: route) }
    }

    /// A window installed its workspace content or mounted a pane: a show that waited for a window
    /// with a pane runs now.
    func windowDidShowContent() {
        guard let request = waiting, let window = services.windows.active, Self.hasPane(window) else { return }
        waiting = nil
        try? show(section: request.section, setting: request.setting, focus: request.focus, route: request.route)
    }

    private static func hasPane(_ window: WindowController) -> Bool {
        window.workspaceContent.map { !$0.modelPanes.isEmpty } ?? false
    }

    /// Shows the workspace of `window` that holds a Settings tab (a daemon page tab, or an app-only
    /// tab in a mounted workspace) when the shown workspace has none and Home does not stand for it.
    private func revealSettingsTab(of window: WindowController) {
        let page = InternalPageID.settings
        func holds(_ content: WorkspaceContentController) -> Bool {
            services.pages.tab(of: page, inPanes: content.modelPanes.map(\.id)) != nil
                || content.workspace.screens.contains { $0.panes.contains { $0.tabs.contains { $0.page == page.rawValue } } }
        }
        if let shown = window.content, holds(shown) { return }
        let homeHidden = SidebarBridge.hidesHome(services.sidebarLayout.document)
        let mounted = window.mountedContents.filter(holds).map(\.workspace)
        let members = services.windows.registry.members(of: window.state.id).compactMap { services.machines.workspace(id: $0)?.0 }
            .filter { $0.screens.contains { $0.panes.contains { $0.tabs.contains { $0.page == page.rawValue } } } }
        guard let workspace = (mounted + members).first(where: { !(homeHidden && $0.kind == "home") }),
              let shown = services.windows.reveal(workspaceID: workspace.id) else { return }
        if !shown.leaveTopPage() { shown.showWorkspace(requested: workspace.id) }
    }

    /// Whether a Settings tab in `window` would be seen: the window shows (or can leave its top
    /// page for) a workspace with a pane, and Home does not stand for that workspace.
    private static func holdsTab(_ window: WindowController, _ services: AppServices) -> Bool {
        window.shownTopPage != .page(.settings) && window.holdsVisiblePageTab
    }

    /// Settings as `window`'s top page (one view per window, shown again on a repeat), on `route`.
    private func showTopPage(in window: WindowController, route: String?) {
        let pageRoute = TopPageRoute.page(.settings)
        // A top page is made at its show: a page made now opens on `route`.
        opens.during(route) { _ = TopPages.show(pageRoute, services: services, in: window.state) }
        if let route, let page = (window.topPages.views[pageRoute] as? InternalPageView)?.content as? PageWebView,
           page.route != route { page.open(route: route) }
    }

    /// The page fragment for `section` and `setting`: a schema setting focuses its row; any other
    /// anchor opens its section.
    /// The art picker, for `workspace` too when given (its This Workspace choice).
    static func backgroundRoute(workspace: String?) -> String? {
        guard let route = route(section: .appearance, setting: "appearance.background") else { return nil }
        guard let workspace, let id = workspace.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return route }
        return "\(route)&workspace=\(id)"
    }

    /// The Development section (and its keys) exists only in DEV builds: elsewhere a request for
    /// it opens Settings on the default page (the page hides the category the same way).
    static func route(section: SettingsSection?, setting: String?, devBuild: Bool = DevTools.isDebugBuild) -> String? {
        if let setting, let descriptor = SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: setting)) {
            guard descriptor.section != .development || devBuild else { return nil }
            return "#/settings/\(descriptor.section.rawValue)?focus=\(descriptor.id)"
        }
        guard let section, section != .development || devBuild else { return nil }
        return "#/settings/\(section.rawValue)"
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .settings }
    var title: String { SettingsDeepLink.pageTitle }
    var symbol: String { "gearshape" }
    var icon: IconName? { .settings }

    /// The kept page when no other tab shows it, else a new one (a second window's tab), on the
    /// route the tab's show asked for.
    func makeView(for key: String, in window: WindowController?) -> NSView {
        let route = opens.take(for: key) ?? opens.running
        if let webPage, webPage.view.superview == nil {
            // Not compared with `route`, the last place asked for: the page may have moved on.
            if let route { webPage.view.open(route: route) }
            tabPages[key] = webPage
            return webPage.view
        }
        let edits = SettingsPageProvider.Edits()
        guard let view = PageFactory(services: services).settingsPage(route: route, edits: edits) else { return NSView() }
        let page = Page(view: view, edits: edits)
        if webPage == nil { webPage = page }
        tabPages[key] = page
        return view
    }

    func tabClosed(_ key: String) {
        tabPages.removeValue(forKey: key)
        opens.forget(key)
        // A live preview left by a closed page (mid-drag) must not stay applied.
        services.settings?.endPreview()
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden: each change is written as it is made, so what a rebuilt page loses is
    /// only what ``keepReasons(for:)`` keeps it for.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// Kept while its page has a form with typed values not saved yet (a custom density, a relay's
    /// fields) or a live preview runs (a value shown and not written: a slider mid-drag, a palette
    /// row): Chrome's kUserEdits.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        let unsavedForm = tabPages[key]?.edits.hasUnsaved == true
        return unsavedForm || services.settings?.previewingKey != nil ? [.unsavedEdits] : []
    }

    /// The section the page shows now (the person may have picked another in the page).
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        await (content as? PageWebView)?.discardViewState() ?? ContentViewState()
    }

    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) async {
        (content as? PageWebView)?.restoreDiscardViewState(state)
    }

    /// The tab's page went (the tab store closed it): a later show builds a new one.
    func viewDiscarded(_ key: String) {
        guard let page = tabPages.removeValue(forKey: key) else { return }
        if page.view === webPage?.view { webPage = nil }
        services.webUI.close(page.view)
    }

    // MARK: Host facts (the page's host lists)

    var rooms: [SettingsListRow]? {
        let local = services.machines.local
        guard local.supports(DaemonCapability.profiles.rawValue) else { return nil }
        let current = services.windows.active?.state.profileID ?? .defaultProfile
        return local.store.profiles.sorted { $0.index < $1.index }.map { room in
            SettingsListRow.space(id: room.id.rawValue, title: room.name, icon: room.icon, isActive: room.id == current)
        }
    }

    var machines: [SettingsListRow] {
        let machines = services.machines
        let ssh = machines.ssh.map { session in
            SettingsListRow.machine(id: session.machineID, title: session.host.label, subtitle: session.host.destination.description,
                                    icon: machines.icon(machine: session.machineID), symbol: "server.rack",
                                    isActive: Self.isConnected(session.daemon.store.connectionState))
        }
        let cloud = machines.cloud.map { session in
            SettingsListRow.machine(id: session.machineID, title: session.machine.title, icon: machines.icon(machine: session.machineID),
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

    /// The window opacity the window shows (`ThemeScope.shownWindowOpacity`), so the unset slider
    /// sits where the window is: read through the active window's theme scope (the app scope when
    /// no window is open), which inherits the app theme unless a room overrides it.
    func derivedNumber(at path: [String]) -> Double? {
        path == WindowBackgroundSetting.opacityPath ? (services.windows.active?.themeScope ?? ThemeScope.app).shownWindowOpacity : nil
    }

    var browserProfiles: [SettingsBrowserProfileRow] {
        services.browserProfiles.ordered.map { record in
            SettingsBrowserProfileRow(id: record.id, name: record.name, color: record.color, icon: record.icon,
                                      isDefault: record.isDefault, source: record.source?["display_name"])
        }
    }
}
