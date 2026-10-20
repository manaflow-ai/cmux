import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextControl
import typealias CmuxNextDaemon.SurfaceID
import CmuxNextIcons
import CmuxNextMacScreen
import CmuxNextSettings
import Foundation

extension InternalPageID {
    /// Mac Screen: a paired Mac's screen, or the home page (paired Macs,
    /// pairing, Share This Mac). Its own tab kind, not a browser page.
    nonisolated static let macScreen = InternalPageID(rawValue: "mac-screen")
}

extension MacScreenTabView: InternalPageFocusing {}

/// Mac Screen page tabs: the app's side (where tabs open, close and retitle);
/// `MacScreenPages` owns each tab's screen. A tab's route is its record
/// ("home" or "mac:<saved Mac id>", never a secret), so a relaunched or
/// reopened tab shows it again, behind the Connect card.
final class MacScreenPageService: InternalPageProvider {
    // crash-allow: AppServices owns this service for the app's whole life (a lazy property), so it outlives it.
    private unowned let services: AppServices
    /// Browser tabs on a Mac Screen address already being replaced.
    private var replacing: Set<String> = []

    init(services: AppServices) {
        self.services = services
        var events = MacScreenTabEvents()
        events.titleChanged = { [weak self] key in
            guard let pane = self?.services.paneController(showingTab: key) else { return }
            pane.apply(pane.snapshot())
        }
        events.openInNewTab = { [weak self] record, key in
            guard let self, let pane = services.paneController(showingTab: key) ?? services.windows.active?.focusedPane else { return }
            open(record, in: pane, focus: true, byPerson: true)
        }
        events.closeTab = { [weak self] key in self?.close(key) }
        events.routeTitlesChanged = { [weak self] in
            // Unopened restored tabs take their device names (read from disk or the hub).
            for controller in self?.services.windows.controllers ?? [] {
                for pane in controller.content?.panes.values.map({ $0 }) ?? [] { pane.apply(pane.snapshot()) }
            }
        }
        events.replaceTab = { [weak self] record, key in self?.replace(key, with: record) ?? false }
        events.storeTabID = { [weak self] key in
            guard let self, let pane = services.paneController(showingTab: key),
                  let id = services.pages.stripID(showing: key, in: pane), id.rawValue != key else { return nil }
            return id.rawValue
        }
        pages.events = events
    }

    /// Closes the Mac Screen tab `key` like the tab's own close. `replaced`:
    /// another tab took its place (Connect on the home page), so no
    /// “Closed” undo toast offers it back.
    private func close(_ key: String, replaced: Bool = false) {
        guard let pane = services.paneController(showingTab: key), let id = services.pages.stripID(showing: key, in: pane) else { return }
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
        guard let pane = services.paneController(showingTab: key), let id = services.pages.stripID(showing: key, in: pane) else { return false }
        // The new tab goes after the selected one: this one.
        if pane.stripModel.selectedID != id { pane.select(id) }
        open(record, in: pane, focus: true, byPerson: true) { [weak self] in self?.close(key, replaced: true) }
        return true
    }

    private var pages: MacScreenPages { services.macScreenPages }

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
        guard let pane = pane ?? services.windows.active?.focusedPane else { return }
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
            guard let self else { return }
            if let pane = services.paneController(listing: key) {
                open(record, in: pane, focus: pane.stripModel.selectedID?.rawValue == key, byPerson: false)
            }
            services.cache.pageRequests.closeTab(key)
        }
    }
}

extension AppServices {
    static func makeMacScreenPages(_ services: AppServices) -> MacScreenPages {
        let pages = MacScreenPages(store: .forApplication(bundleIdentifier: services.environment.launch.bundleID))
        pages.useShortcuts(of: services.registry)
        return pages
    }

    /// Keyboard > Mac Screen > Send System Shortcuts to the Remote Mac drives the
    /// system shortcut tap; the toolbar's menu item writes the same setting.
    /// DEV builds: Settings > Development > Relay Only drives every Mac Screen session.
    func followMacScreenSettings(_ settings: SettingsController) {
        let shortcuts = macScreenPages.systemShortcuts
        shortcuts.setEnabled = { [weak settings, weak self] on in
            // The setting is user-only, the same writer check as Settings: any
            // in-app UI interaction (mouse, keyboard, accessibility press) is the
            // user; an automation run (CLI, agents, scripts, the socket) is refused.
            let writer = Self.systemShortcutsWriter(run: ActionRunScope.current)
            guard let descriptor = SettingsSchema.descriptor(for: MacScreenSettings.systemShortcutsPath) else { return }
            // task-owner: one settings write per menu or switch change
            Task {
                do { try await settings?.setSetting(descriptor, to: .bool(on), by: writer) } catch is SettingUserOnly {
                    self?.registry.refuse(String(describing: SettingUserOnly(key: descriptor.id, writer: writer)))
                } catch {}
            }
        }
        Task { [weak shortcuts] in
            for await on in ObservationStream({ settings.snapshot.macScreen.systemShortcuts }) {
                shortcuts?.enabled = on
            }
        }
        #if DEBUG
        Task { [weak self] in
            for await relayOnly in ObservationStream({ settings.snapshot.macScreenDebug.relayOnly }) {
                self?.macScreenPages.relayOnly = relayOnly
            }
        }
        #endif
    }

    /// Who is changing Send System Shortcuts to the Remote Mac from Mac
    /// Screen: an automation run's origin, else (a gesture in this app's UI) the user.
    nonisolated static func systemShortcutsWriter(run: ActionRunScope?) -> SettingWriter {
        run.map { SettingWriter($0.origin) } ?? .user
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
        macScreenPages.registerDebug(on: router) { [weak self] record, key in
            let named = key.flatMap { key in self?.windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.paneKey == key } }.first }
            guard let self, let pane = named ?? windows.active?.focusedPane ?? windows.controllers.first?.focusedPane else { return "no pane" }
            macScreenTabs.open(record, in: pane, focus: true, byPerson: false)
            return nil
        }
    }
}
