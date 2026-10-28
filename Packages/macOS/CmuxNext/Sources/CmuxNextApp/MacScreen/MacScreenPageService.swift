import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextControl
import typealias CmuxNextDaemon.SurfaceID
import CmuxNextIcons
import CmuxNextMacScreen
import CmuxNextSettings
import Foundation

extension InternalPageID {
    /// Mac Screen: one of the user's devices' screens, or the home page (the
    /// user's devices, Allow Mac Screen on This Mac). Its own tab kind, not a browser page.
    nonisolated static let macScreen = InternalPageID(rawValue: "mac-screen")
}

extension MacScreenTabView: InternalPageFocusing {}

/// Mac Screen page tabs: the app's side (where tabs open, close and retitle);
/// `MacScreenPages` owns each tab's screen. A tab's route is its record
/// ("home" or "device:<device id>", never a secret), so a relaunched or
/// reopened tab shows it again, behind the Connect card.
final class MacScreenPageService: InternalPageProvider {
    /// Weak: AppServices owns this service (a lazy property), never the other way round.
    private weak var services: AppServices?
    /// The tabs' screens; AppServices made them before this service.
    private let pages: MacScreenPages
    /// Browser tabs on a Mac Screen address already being replaced.
    private var replacing: Set<String> = []

    init(services: AppServices) {
        self.services = services
        pages = services.macScreenPages
        var events = MacScreenTabEvents()
        events.titleChanged = { [weak self] key in
            guard let pane = self?.services?.paneController(showingTab: key) else { return }
            pane.apply(pane.snapshot())
        }
        events.openInNewTab = { [weak self] record, key in
            guard let self, let services = self.services,
                  let pane = services.paneController(showingTab: key) ?? services.windows.active?.focusedPane else { return }
            open(record, in: pane, focus: true, byPerson: true)
        }
        events.closeTab = { [weak self] key in self?.close(key) }
        events.routeTitlesChanged = { [weak self] in
            // Unopened restored tabs take their device names (read from disk or the hub).
            for controller in self?.services?.windows.controllers ?? [] {
                for pane in controller.content?.panes.values.map({ $0 }) ?? [] { pane.apply(pane.snapshot()) }
            }
        }
        events.replaceTab = { [weak self] record, key in self?.replace(key, with: record) ?? false }
        events.storeTabID = { [weak self] key in
            guard let self, let services = self.services, let pane = services.paneController(showingTab: key),
                  let id = services.pages.stripID(showing: key, in: pane), id.rawValue != key else { return nil }
            return id.rawValue
        }
        pages.events = events
    }

    /// Closes the Mac Screen tab `key` like the tab's own close. `replaced`:
    /// another tab took its place (Connect on the home page), so no
    /// “Closed” undo toast offers it back.
    private func close(_ key: String, replaced: Bool = false) {
        guard let services, let pane = services.paneController(showingTab: key), let id = services.pages.stripID(showing: key, in: pane) else { return }
        services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id.rawValue),
                                                                          origin: replaced ? .script : .user))
    }

    /// A person asked tab `key` to show `record` (the home page's Connect,
    /// a screen's Home): `record` opens as a new tab right after `key`,
    /// selected and confirmed, and `key` closes once the new tab exists (a
    /// store tab once the daemon made it, so a pane whose only tab was `key`
    /// never empties and closes). The new tab's route names `record`, so a
    /// relaunch shows the same Mac. False when no pane lists `key`.
    private func replace(_ key: String, with record: MacScreenRecord) -> Bool {
        guard let services, let pane = services.paneController(showingTab: key), let id = services.pages.stripID(showing: key, in: pane) else { return false }
        // The new tab goes after the selected one: this one.
        if pane.stripModel.selectedID != id { pane.select(id) }
        open(record, in: pane, focus: true, byPerson: true) { [weak self] in self?.close(key, replaced: true) }
        return true
    }

    var page: InternalPageID { .macScreen }
    var title: String { MacScreenPages.homeTitle }
    var symbol: String { "display" }
    var icon: IconName? { .remoteDisplay }

    func title(for key: String) -> String { pages.title(for: key) }
    func makeView(for key: String, in window: WindowController?) -> NSView { pages.makeView(for: key) }
    func tabClosed(_ key: String) { pages.tabClosed(key) }
    func route(for key: String) -> String? { pages.route(for: key) }
    func restore(_ route: String, for key: String) { pages.restore(route, for: key) }
    func title(forRoute route: String) -> String? { pages.title(forRoute: route) }

    /// Opens a Mac Screen tab showing `record` after `pane`'s selected tab: a
    /// store tab where the pane's daemon holds page tabs, else an app-only
    /// one. `focus` selects and focuses it; `byPerson`: a person asked for it
    /// here, so a Mac's screen connects without asking. `created` runs once
    /// the tab exists (a store tab: once the daemon made it).
    @discardableResult
    func open(_ record: MacScreenRecord, in pane: PaneController, focus: Bool, byPerson: Bool,
              created: (@MainActor () -> Void)? = nil) -> String {
        let key = LocalPageTab.makeKey(.macScreen)
        pages.prepare(key, record: record, byPerson: byPerson)
        guard let services else { return key }
        let window = services.windowController(showing: pane)
        var onCreated: (@MainActor (SurfaceID) -> Void)?
        if let created { onCreated = { _ in created() } }
        if let window, services.pages.openStoreTab(.macScreen, in: pane, window: window, focus: focus, key: key,
                                                   created: onCreated) != nil {
            return key
        }
        services.pages.open(.macScreen, in: pane.paneKey, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue,
                            window: window, key: key)
        pane.apply(pane.snapshot())
        if focus { services.pages.reveal(key, in: pane) }
        created?()
        return key
    }

    /// A Mac Screen address (`cmux://mac-screen…`) typed in a browser's
    /// address bar or opened as a browser tab: its tab opens in `pane`, else
    /// the active window's focused pane. Only a person's input connects at once.
    func openAddress(_ record: MacScreenRecord, in pane: PaneController?, focus: Bool) {
        guard let pane = pane ?? services?.windows.active?.focusedPane else { return }
        open(record, in: pane, focus: focus, byPerson: RemoteViewPageService.isPersonInput(ActionRunScope.current))
    }

    /// A browser tab whose record is a Mac Screen address (made before Mac
    /// Screen had its own tab kind): the Mac Screen tab opens beside it,
    /// waiting for Connect, and the browser tab closes. Once per tab.
    func replaceBrowserTab(_ key: String, url: URL) {
        guard replacing.insert(key).inserted else { return }
        let record = MacScreenRecord(url: url) ?? MacScreenRecord(macID: nil)
        // task-owner: one replacement after the snapshot that listed the tab is applied
        Task { @MainActor [weak self] in
            guard let self, let services else { return }
            if let pane = services.paneController(listing: key) {
                open(record, in: pane, focus: pane.stripModel.selectedID?.rawValue == key, byPerson: false)
            }
            services.cache.pageRequests.closeTab(key)
        }
    }
}

extension AppServices {
    static func makeMacScreenPages(_ services: AppServices) -> MacScreenPages {
        let pages = MacScreenPages(store: .forApplication(bundleIdentifier: services.environment.launch.bundleID), work: services.work)
        pages.useShortcuts(of: services.registry)
        pages.hubHost.indicatorMenuItem = { [weak registry = services.registry] in registry?.makeMenuItem(for: $0) }
        return pages
    }

    /// The device hub follows the cmux account (CloudAuth).
    static func makeDeviceHub(_ services: AppServices) -> DeviceHubService {
        let auth = services.cloud.auth
        let account = DeviceHubService.Account(awaitRestored: { await auth.awaitRestored() },
                                                userID: { auth.isSignedIn ? (auth.user?.id ?? "") : nil },
                                                accessToken: { try await auth.tokens().access })
        return DeviceHubService(pages: services.macScreenPages, account: account, bundleIdentifier: services.environment.launch.bundleID)
    }

    /// Mac Screen follows its settings (Send System Shortcuts; DEV: Relay Only).
    func followMacScreenSettings(_ settings: SettingsController) {
        macScreenPages.follow(settings) { [weak self] in self?.registry.refuse($0) }
    }

    /// New Mac Screen Tab: the home page in the pane the action ran on, else the active window's focused pane.
    func openMacScreen(in target: PaneController?) {
        guard let pane = target ?? windows.active?.focusedPane else { return registry.refuse(RefusalStrings.noWindowOpen) }
        macScreenTabs.open(MacScreenRecord(macID: nil), in: pane, focus: true, byPerson: true)
    }

    /// The pane whose strip lists tab `key` (any kind of tab).
    func paneController(listing key: String) -> PaneController? {
        windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.tab(StripTabID(key)) != nil } }.first
    }

    func registerMacScreenDebug(on router: ControlRouter?) {
        macScreenPages.registerDebug(on: router) { [weak self] record, key in self?.openDebugMacScreen(record, pane: key, byPerson: false) ?? "no pane" }
    }

    /// The device hub follows the hub address (`deviceHub.url` in DEV builds) and the cmux account.
    func startDeviceHub(_ settings: SettingsController) {
        deviceHub.start(settings: settings)
        cloud.willSignOut.append { [weak self] in self?.deviceHub.willSignOut() }
    }

    /// `debug.device_hub` (DEV builds).
    func registerDeviceHubDebug(on router: ControlRouter?) {
        macScreenPages.registerDeviceHubDebug(on: router, settings: deviceHub.settingsModel) { [weak self] record, key in
            self?.openDebugMacScreen(record, pane: key, byPerson: true) ?? "no pane"
        }
    }

    /// A debug method's Mac Screen tab: in the pane named `key`, else the active or first window's focused pane.
    private func openDebugMacScreen(_ record: MacScreenRecord, pane key: String?, byPerson: Bool) -> String? {
        let named = key.flatMap { key in windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.paneKey == key } }.first }
        guard let pane = named ?? windows.active?.focusedPane ?? windows.controllers.first?.focusedPane else { return "no pane" }
        macScreenTabs.open(record, in: pane, focus: true, byPerson: byPerson)
        return nil
    }
}
