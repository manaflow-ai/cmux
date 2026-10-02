import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextTabs

/// Agent chat tabs (the React acpmux pane, CmuxNextAgentPane). cmux-tui has
/// no agent tab kind yet, so like `LocalBrowserTab` they live only in this
/// app session and are not restored after relaunch; the acpmux sessions they
/// show are durable in acpmux. Ids carry `prefix` so every tab path can tell
/// them from daemon tabs.
enum LocalAgentTab {
    static let prefix = "local-agent:"
}

/// Which agent tabs each pane lists, and their pane views. One acpmux host is
/// shared by every tab, so opening several at once starts one daemon.
final class AgentTabStore {
    private let host: any AgentPaneHostProviding
    /// The page every agent tab loads: the bundled file, or in Debug builds
    /// the dev server `CMUX_NEXT_AGENT_PANE_DEV_URL` names (nil only when the
    /// bundled page is missing).
    private let source: AgentPaneSource?
    /// Adaptive, or in Debug builds fixed by `CMUX_NEXT_AGENT_PANE_FULL_RATE`
    /// (`1` full, `0` capped) for measuring either rate.
    private let renderRate: AgentPaneRenderRate
    /// `~/.config/cmux/agent-pane/` hot reload, watched while any agent tab
    /// has a view.
    private let customization: AgentPaneCustomizationWatcher
    private var tabsByPane: [String: [String]] = [:]
    private var views: [String: AgentPaneView] = [:]
    /// Chats outside any pane (onboarding's first task), weakly held, so
    /// they get customization changes too.
    private let standaloneViews = NSHashTable<AgentPaneView>.weakObjects()
    /// Session each tab last showed, kept across a web content crash or a
    /// view rebuilt after the tab was released.
    private var sessions: [String: String] = [:]
    /// Tabs opened as the new tab page, and what each does with the kind
    /// the user picks there (``PaneController/newTabPage()``).
    private var newTabPages: [String: (page: AgentPaneNewTab, handler: NewTabPageHandler)] = [:]
    /// What each new chat inherits from the tab it was opened from, until
    /// its view reads it.
    private var seeds: [String: AgentPaneSeedSource] = [:]
    /// The daemon tree each pane with agent tabs belongs to. It is watched,
    /// so the tabs of a pane closed out of sight (its window showing another
    /// workspace, its daemon away) close once the live tree drops the pane.
    private var paneStores: [String: DaemonStore] = [:]
    private var watches: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The app shortcuts every agent page shows, kept current on rebinds.
    private var shortcuts = AgentPaneShortcuts()
    private var shortcutObservation: Task<Void, Never>?
    private weak var actionRegistry: ActionRegistry?
    private var checkpointFocusTab: String?
    /// This build's URL scheme, handed to every page for the links it copies.
    private let linkScheme: String?

    init(tag: String?, registry: ActionRegistry, environment: [String: String] = ProcessInfo.processInfo.environment,
         linkScheme: String? = nil) {
        actionRegistry = registry
        self.linkScheme = linkScheme
        if environment["CMUX_NEXT_AGENT_PANE_MOCK"] == "1" {
            host = MockAgentPaneHost()
        } else {
            let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
            host = AcpmuxHost { AcpmuxEnvironment.resolve(tag: tag, bundledBinDirectory: bin, environment: environment) }
        }
        // Release loads only the bundled page; the dev server is for Debug
        // and tagged builds (webviews/src/agent-session/acpmux/README.md).
        #if DEBUG
        let allowsDevServer = true
        #else
        let allowsDevServer = false
        #endif
        #if DEBUG
        switch environment["CMUX_NEXT_AGENT_PANE_FULL_RATE"] {
        case "1": renderRate = .full
        case "0": renderRate = .capped
        default: renderRate = .adaptive
        }
        #else
        renderRate = .adaptive
        #endif
        source = AgentPaneSource.resolve(
            environment: environment, bundledPage: AgentPaneView.bundledPage, allowsDevServer: allowsDevServer
        )
        customization = AgentPaneCustomizationWatcher(
            directory: AgentPaneCustomization.directory(configFile: CmuxConfigFile.defaultURL(environment: environment))
        )
        customization.onChange = { [weak self] value in
            guard let self else { return }
            for view in views.values { view.customization = value }
            for view in standaloneViews.allObjects { view.customization = value }
        }
        shortcuts = AgentPaneShortcuts.read(registry)
        // Rebinds in Settings or cmux.json reach every open page.
        shortcutObservation = Task { [weak self] in
            for await value in Observations({ AgentPaneShortcuts.read(registry) }) {
                guard let self else { return }
                shortcuts = value
                for view in views.values { view.shortcuts = value }
                for view in standaloneViews.allObjects { view.shortcuts = value }
            }
        }
    }

    /// Adds a new chat tab to `paneKey`'s strip and returns its id.
    ///
    /// - Parameters:
    ///   - paneKey: The pane's id (`PaneModel.id`).
    ///   - store: The tree of the daemon that owns the pane.
    ///   - after: The tab to place it after; nil appends it.
    ///   - session: The acpmux session it shows; nil starts a new chat.
    ///   - newTab: Shows the new tab page until it becomes a chat; the
    ///     handler gets the terminal or browser choices and shortcut edits.
    ///   - seed: What a new chat inherits (cwd, a draft); ignored with a session.
    func open(in paneKey: String, of store: DaemonStore, after: String? = nil, session: String? = nil,
              seed: AgentPaneSeedSource? = nil,
              newTab: (page: AgentPaneNewTab, handler: NewTabPageHandler)? = nil) -> String {
        let key = LocalAgentTab.prefix + UUID().uuidString.lowercased()
        var tabs = tabsByPane[paneKey] ?? []
        if let after, let index = tabs.firstIndex(of: after) {
            tabs.insert(key, at: index + 1)
        } else {
            tabs.append(key)
        }
        tabsByPane[paneKey] = tabs
        sessions[key] = session
        newTabPages[key] = newTab
        if session == nil { seeds[key] = seed }
        paneStores[paneKey] = store
        watch(store)
        return key
    }

    /// Duplicate Tab: a new tab in `paneKey` after `key`, showing its session.
    func duplicate(_ key: String, in paneKey: String, of store: DaemonStore) -> String {
        open(in: paneKey, of: store, after: key, session: sessions[key])
    }

    func tabIDs(in paneKey: String) -> [String] { tabsByPane[paneKey] ?? [] }

    /// The tab showing acpmux session `session` (`cmux://session/<id>`), if any.
    func tab(showing session: String) -> String? {
        for keys in tabsByPane.values {
            if let key = keys.first(where: { sessions[$0] == session }) { return key }
        }
        return nil
    }

    /// The pane (`PaneModel.id`) whose strip lists agent tab `key`.
    func paneKey(listing key: String) -> String? {
        tabsByPane.first { $0.value.contains(key) }?.key
    }

    func stripItem(_ key: String) -> StripTabItem {
        StripTabItem(id: StripTabID(key), title: AgentPaneModel.tabTitle, subtitle: nil,
                     icon: .symbol("bubble.left.and.text.bubble.right"), isBusy: false)
    }

    /// The tab's pane view, made on first show.
    func view(for key: String) -> AgentPaneView? {
        if let view = views[key] { return view }
        guard tabsByPane.values.contains(where: { $0.contains(key) }) else { return nil }
        let model = AgentPaneModel(
            host: host,
            sessionId: sessions[key],
            seed: seeds.removeValue(forKey: key),
            newTab: newTabPages[key]?.page
        )
        model.linkScheme = linkScheme
        model.onSessionChange = { [weak self] session in
            self?.sessions[key] = session
            self?.newTabPages[key] = nil
        }
        model.onOpenTab = { [weak self] kind, text in self?.newTabPages[key]?.handler.open(key, kind, text) }
        model.onEditShortcut = { [weak self] kind in self?.newTabPages[key]?.handler.editShortcut(kind) }
        model.onCheckpointAvailability = { [weak self] _ in self?.publishCheckpointAvailability() }
        guard let source, let view = AgentPaneView(model: model, source: source, renderRate: renderRate) else { return nil }
        view.customization = customization.current
        view.shortcuts = shortcuts
        views[key] = view
        customization.start()
        return view
    }

    func existingView(_ key: String) -> AgentPaneView? { views[key] }

    /// A new chat outside any pane (onboarding's first task), on the same
    /// daemon and page as the tabs. The caller owns it and closes it.
    func standaloneView(seed: AgentPaneSeed) -> AgentPaneView? {
        let model = AgentPaneModel(host: host, seed: AgentPaneSeedSource(seed))
        model.linkScheme = linkScheme
        guard let source, let view = AgentPaneView(model: model, source: source, renderRate: renderRate) else { return nil }
        view.customization = customization.current
        view.shortcuts = shortcuts
        standaloneViews.add(view)
        customization.start()
        return view
    }

    /// True when this build has the agent page (bundled or dev server).
    var canHostChat: Bool { source != nil }

    /// Focus changes and the page's capability mirror update one registry fact.
    func setCheckpointFocus(_ key: String?) {
        checkpointFocusTab = key
        publishCheckpointAvailability()
    }
    private func publishCheckpointAvailability() {
        guard let registry = actionRegistry else { return }
        let available = checkpointFocusTab.flatMap { views[$0] }?.model.checkpointAvailable == true
        var next = registry.context
        if available { next.insert(.checkpointCaptureAvailable) }
        else { next.remove(.checkpointCaptureAvailable) }
        if next != registry.context { registry.context = next }
    }

    /// The tab closed: stop its page and forget it.
    func close(_ key: String) {
        for pane in tabsByPane.keys { tabsByPane[pane]?.removeAll { $0 == key } }
        tabsByPane = tabsByPane.filter { !$0.value.isEmpty }
        views.removeValue(forKey: key)?.close()
        sessions[key] = nil
        newTabPages[key] = nil
        seeds[key] = nil
        forgetUnusedStores()
        stopCustomizationWhenUnused()
    }

    /// The pane closed: stop every agent tab it listed.
    func closePane(_ paneKey: String) {
        for key in tabsByPane.removeValue(forKey: paneKey) ?? [] {
            views.removeValue(forKey: key)?.close()
            sessions[key] = nil
            newTabPages[key] = nil
            seeds[key] = nil
        }
        forgetUnusedStores()
        stopCustomizationWhenUnused()
    }

    /// Closes the agent tabs of every pane `store` no longer lists, once it
    /// is connected with a live tree. While the daemon is away its panes
    /// keep their tabs.
    func closeGonePanes(in store: DaemonStore) {
        guard let live = Self.livePanes(store) else { return }
        for (paneKey, owner) in paneStores where owner === store && !live.contains(paneKey) {
            closePane(paneKey)
        }
    }

    private static func livePanes(_ store: DaemonStore) -> Set<String>? {
        guard case .connected = store.connectionState, store.isLoaded else { return nil }
        return Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).map(\.id))
    }

    private func watch(_ store: DaemonStore) {
        let id = ObjectIdentifier(store)
        guard watches[id] == nil else { return }
        // task-owner: stored in watches; cancelled once no pane of the store has agent tabs
        watches[id] = Task { [weak self] in
            for await live in Observations({ Self.livePanes(store) }) where live != nil {
                guard let self else { return }
                self.closeGonePanes(in: store)
            }
        }
    }

    private func forgetUnusedStores() {
        paneStores = paneStores.filter { tabsByPane[$0.key] != nil }
        let used = Set(paneStores.values.map { ObjectIdentifier($0) })
        for id in watches.keys where !used.contains(id) {
            watches.removeValue(forKey: id)?.cancel()
        }
    }

    private func stopCustomizationWhenUnused() {
        if views.isEmpty, standaloneViews.allObjects.isEmpty { customization.stop() }
    }
}

extension PaneController {
    /// New Agent Chat: a new agent tab in this pane, selected. It inherits
    /// the selected tab's context (`agentSeedFromSelectedTab`, #16620).
    func newAgentTab() {
        showAgentTab(services.agentTabs.open(in: paneKey, of: daemon.store, seed: agentSeedFromSelectedTab()))
    }

    /// A `cmux://session/<id>` link no tab shows: a new agent tab in this
    /// pane on that session, selected, as Duplicate Tab opens one. Returns
    /// its id.
    @discardableResult
    func openAgentSession(_ session: String) -> String {
        let key = services.agentTabs.open(in: paneKey, of: daemon.store, session: session)
        showAgentTab(key)
        return key
    }

    /// Duplicate Tab on an agent tab: the same session, right after it.
    func duplicateAgentTab(_ key: String) {
        showAgentTab(services.agentTabs.duplicate(key, in: paneKey, of: daemon.store))
    }

    func showAgentTab(_ key: String) {
        apply(snapshot())
        select(StripTabID(key))
    }
}
