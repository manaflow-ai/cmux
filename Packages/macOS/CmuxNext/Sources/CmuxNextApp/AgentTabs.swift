import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextTabs

/// The pane views of agent chat tabs (the React acpmux pane, CmuxNextAgentPane).
///
/// An agent chat tab is a workspace store tab: a `conversation` tab whose source is an acpmux
/// session (`agent-session-tabs-v1`, cmux-tui/spec/commands.md new-conversation-tab). The store owns which
/// pane lists it, its order, and its session; it restores it after relaunch (R138) and moves,
/// splits and closes it like any tab. This type owns only client view state, keyed by tab id
/// (`TabModel.id`): the page views, a new chat's seed, the new tab page, link and turn requests.
/// One acpmux host is shared by every tab, so opening several at once starts one daemon.
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
    /// The store record of agent tab `key` and the tree that lists it; nil for any other tab
    /// (AppServices looks in every machine's tree).
    var lookup: @MainActor (String) -> (record: AgentSessionRef, store: DaemonStore)? = { _ in nil }
    /// Every agent tab the trees list, with its record.
    var listTabs: @MainActor () -> [(key: String, record: AgentSessionRef)] = { [] }
    /// Creates the store tab with idempotency key `key` (AppServices: `new-conversation-tab` on
    /// the pane's daemon). Returns it and the daemon event sequence read after the reply (nil
    /// when the connection ended: the next snapshot holds the tab).
    var create: @MainActor (_ pane: PaneID, _ daemon: DaemonService, _ record: AgentSessionRef, _ key: String,
                            _ transaction: ClientTransactionID) async throws
        -> (created: AgentTabCreated, sequence: UInt64?) = { _, _, _, _, _ in throw DaemonError.notConnected }
    /// Moves a pane's selection from provisional tab `provisional` to the created tab's surface,
    /// where the pane still selects it (AppServices: every pane controller).
    var moveSelection: @MainActor (_ provisional: String, _ surface: SurfaceID) -> Void = { _, _ in }
    /// Whether `daemon` holds agent session tabs (`agent-session-tabs-v1`).
    var holdsTabs: @MainActor (DaemonService) -> Bool = { $0.supports(DaemonCapabilities.shared.agentSessionTabs) }
    /// Sets tab `surface`'s session by compare-and-swap from `expected` (AppServices:
    /// `bind-conversation-tab-session` on the tab's daemon): the store's answer and, when it took
    /// it, the daemon event sequence read after the reply (nil when the connection ended).
    var bind: @MainActor (_ key: String, _ surface: SurfaceID, _ expected: String?, _ session: String) async
        -> (outcome: AgentSessionBindOutcome, sequence: UInt64?) = { _, _, _, _ in (.taken, nil) }
    /// Whether `daemon` is connected now: a disconnected owner refuses changes, nothing queues.
    var reachable: @MainActor (DaemonService) -> Bool = { $0.connection != nil }
    /// Tabs closed while the store was still creating them: closed when it answers.
    var pendingCloses: [String: @MainActor (String) -> Void] = [:]
    /// This Mac's name for other Macs that show its tabs ("This chat runs on <name>"): at most
    /// 255 bytes, no control characters (the store refuses others).
    var localHostName: String? {
        didSet { localHostName = localHostName.flatMap(Self.displayName) }
    }
    /// Reads this Mac's `install:<id>` (AppServices: the Cloud device id), on need.
    var resolveLocalHost: @MainActor () -> String? = { nil }
    private var resolvedLocalHost: String?
    /// `install:<id>` of this Mac. Only that host attaches a tab to its acpmux; nil refuses new
    /// tabs. Read again while it is nil (the id file could not be read yet).
    var localHost: String? {
        get {
            if resolvedLocalHost == nil { resolvedLocalHost = resolveLocalHost() }
            return resolvedLocalHost
        }
        set { resolvedLocalHost = newValue }
    }
    var views: [String: AgentPaneView] = [:]
    /// "This chat runs on <machine>" for tabs whose session another Mac's acpmux runs.
    var notices: [String: AgentTabElsewhereView] = [:]
    /// A provisional tab's id -> the store's id once the creation answered
    /// (``AgentTabStore/rekey(_:to:)``): a page shown under either id is one page.
    var aliases: [String: String] = [:]
    /// Tabs a live tree has listed: only those can be gone from it.
    var seenLive: Set<String> = []
    /// The tree each opened or shown tab belongs to, so a tab closed out of sight (by the CLI,
    /// another client, its pane closing) lets its view state go once that tree is live without it.
    var tabStores: [String: DaemonStore] = [:]
    var watches: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Chats outside any pane (onboarding's first task), weakly held, so
    /// they get customization changes too.
    let standaloneViews = NSHashTable<AgentPaneView>.weakObjects()
    /// Takes back a closed, untouched new tab page as the pool's spare
    /// (NewTabSparePool.recycle); false when the pool already has one.
    var recycle: ((AgentPaneView) -> Bool)?
    /// Closed pages leave the view tree at once; their teardown waits (R81).
    let retirer = AgentPageRetirer()
    /// The session each tab's page reported, ahead of the store's echo of the bind and across a
    /// web content crash or a view rebuilt after the tab was released.
    var sessions: [String: String] = [:]
    /// Shared conversion and project actions for a direct blank chat, without a chooser page.
    var blankChatHandler: ((String) -> NewTabPageHandler?)?
    /// The New Tab page a new workspace's first tab shows, starting in the given folder.
    var firstPageNewTab: ((String?) -> (page: AgentPaneNewTab, handler: NewTabPageHandler)?)?

    /// Tabs opened as the chooser page, and the actions for their selected kind.
    var newTabPages: [String: (page: AgentPaneNewTab, handler: NewTabPageHandler)] = [:]
    /// What each new chat inherits from the tab it was opened from, until
    /// its view reads it.
    var seeds: [String: AgentPaneSeedSource] = [:]
    /// The tab resuming each outside chat (`harness:agentSessionId`), so
    /// picking the same chat again shows that tab instead of a second one.
    var adoptions: [String: String] = [:]
    /// The app shortcuts every agent page shows, kept current on rebinds.
    private var shortcuts = AgentPaneShortcuts()
    private var shortcutObservation: Task<Void, Never>?
    /// `labs.previewFeatures`, pushed to every page like the shortcuts.
    private var previewFeatures = false
    private var previewObservation: Task<Void, Never>?
    weak var actionRegistry: ActionRegistry?
    var checkpointFocusTab: String?
    /// This build's URL scheme, handed to every page for the links it copies.
    private let linkScheme: String?
    /// Tabs a `cmux://session/<id>` link opened: their page refuses a
    /// session the daemon does not have instead of falling back.
    var linkedSessions: Set<String> = []
    /// A link's turn for a tab whose view is not made yet.
    var pendingTurns: [String: String] = [:]
    /// The tabs' git reads on the local session host (AgentPaneGitReads.swift);
    /// nil answers the page `native.not_connected`.
    private let git: AgentPaneGitLink?

    /// `settings`, when given, is followed for `labs.previewFeatures`
    /// (AppDelegate makes it before any agent tab).
    init(tag: String?, registry: ActionRegistry, environment: [String: String] = ProcessInfo.processInfo.environment,
         showcase: Bool = false, linkScheme: String? = nil, git: AgentPaneGitLink? = nil, settings: SettingsController? = nil) {
        actionRegistry = registry
        self.linkScheme = linkScheme
        self.git = git
        let (resolvedSource, resolvedHost) = Self.resolvePane(tag: tag, environment: environment, showcase: showcase)
        host = resolvedHost
        // Start acpmux while the first pane is loading. The page still owns
        // the authenticated WebSocket handshake and session selection.
        Task { try? await resolvedHost.prewarm() }
        #if DEBUG
        switch environment["CMUX_NEXT_AGENT_PANE_FULL_RATE"] {
        case "1": renderRate = .full
        case "0": renderRate = .capped
        default: renderRate = .adaptive
        }
        #else
        renderRate = .adaptive
        #endif
        source = resolvedSource
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
        if let settings { follow(settings) }
    }

    /// Follows `labs.previewFeatures` in cmux.json.
    func follow(_ settings: SettingsController) {
        // task-owner: lives as long as the tabs; event-driven (Observation)
        previewObservation = Task { [weak self] in
            for await on in Observations({ settings.snapshot.previewFeatures }) {
                guard let self else { return }
                previewFeatures = on
                for view in views.values { view.previewFeatures = on }
                for view in standaloneViews.allObjects { view.previewFeatures = on }
            }
        }
    }

    /// True when `key` names an agent chat tab in a tree.
    func isAgentTab(_ key: String) -> Bool { lookup(key) != nil }

    /// True when a pane of `daemon` can get a new agent chat tab: this build has the page, this
    /// Mac has an install id, and the daemon holds agent session tabs.
    func canHost(on daemon: DaemonService) -> Bool {
        canHostChat && localHost != nil && holdsTabs(daemon)
    }

    /// The tab showing acpmux session `session` (`cmux://session/<id>`) of this Mac, if any.
    func tab(showing session: String) -> String? {
        let host = localHost
        return listTabs().first { $0.record.host == host && (sessions[$0.key] ?? $0.record.session) == session }?.key
    }

    /// The acpmux session agent tab `key` shows; nil for a new chat.
    func session(of key: String) -> String? {
        let key = resolve(key)
        return sessions[key] ?? lookup(key)?.record.session
    }

    /// The store's id of `key` (a provisional id after its creation answered).
    func resolve(_ key: String) -> String { aliases[key] ?? key }

    /// Scrolls tab `key`'s transcript to `turn` (a `#turn-<turnId>` link):
    /// through its page, or with the handshake of a page not made yet.
    func revealTurn(_ turn: String, in key: String) {
        let key = resolve(key)
        if let view = views[key] { view.revealTurn(turn) } else { pendingTurns[key] = turn }
    }

    /// The link turn tab `key`'s page has not been handed yet.
    func pendingTurn(in key: String) -> String? {
        let key = resolve(key)
        return views[key]?.model.pendingRevealTurn ?? pendingTurns[key]
    }

    /// The tab's pane view, made on first show. Nil for a tab whose session runs on another
    /// machine's acpmux: this Mac does not attach to it.
    func view(for key: String) -> AgentPaneView? {
        let key = resolve(key)
        if let view = views[key] { return view }
        guard let (record, store) = lookup(key), record.host == localHost else { return nil }
        let model = AgentPaneModel(
            host: host,
            sessionId: sessions[key] ?? record.session,
            seed: seeds.removeValue(forKey: key),
            newTab: newTabPages[key]?.page,
            allowsTabConversion: true
        )
        model.sessionMustExist = linkedSessions.contains(key)
        model.pendingRevealTurn = pendingTurns.removeValue(forKey: key)
        wire(model, key: key)
        guard let view = makeView(model) else { return nil }
        views[key] = view
        track(key, in: store)
        return view
    }

    /// A prewarmed new tab page (NewTabSparePool): loaded, rendered and
    /// connected before any tab exists; ``open(in:of:session:seed:newTab:spare:linked:adopt:idempotencyKey:)`` adopts it.
    func makeSpare(_ page: AgentPaneNewTab) -> AgentPaneView? {
        guard let view = makeView(AgentPaneModel(host: host, newTab: page)) else { return nil }
        standaloneViews.add(view)
        return view
    }

    /// Tab `key`'s callbacks on its page's model.
    /// Tab `key`'s callbacks on its page's model. Each resolves the tab's current id when it
    /// runs, so a page made under a provisional id keeps working under the store's.
    func wire(_ model: AgentPaneModel, key provisional: String) {
        model.onSessionChange = { [weak self] session in
            guard let self else { return }
            let key = resolve(provisional)
            newTabPages[key]?.handler.becameChat()
            newTabPages[key] = nil
            views[key]?.applyTheme() // now the agent chat surface (R55)
            sessions[key] = session
            sendSession(session, for: key)
        }
        model.onOpenTab = { [weak self] request in
            BenchSpans.mark("bridge.tab.open")
            guard let self else { return }
            let key = resolve(provisional)
            (newTabPages[key]?.handler ?? blankChatHandler?(key))?.open(key, request)
        }
        model.onTypeAhead = { [weak self] text in
            guard let self else { return }
            let key = resolve(provisional)
            (newTabPages[key]?.handler ?? blankChatHandler?(key))?.typeAhead(key, text)
        }
        model.onRememberNewTab = { [weak self] agent in self?.newTabPage(provisional)?.handler.remember(agent) }
        model.onJump = { [weak self] target, id in self?.newTabPage(provisional)?.handler.jump(target, id) }
        model.onEditShortcut = { [weak self] kind in self?.newTabPage(provisional)?.handler.editShortcut(kind) }
        model.onSetDefaultKind = { [weak self] kind in self?.newTabPage(provisional)?.handler.setDefaultKind(kind) }
        model.onRunAction = { [weak self] id in
            guard let self else { return }
            // On this tab's pane: the New Tab page opens beside the tab that asked.
            let target = ActionTargetRef(kind: .tab, id: resolve(provisional))
            _ = actionRegistry?.perform(ActionID(rawValue: id), invocation: ActionInvocation(target: target, origin: .user))
        }
        model.onBrowseProject = { [weak self] in
            guard let self, let handler = newTabPages[resolve(provisional)]?.handler ?? blankChatHandler?(resolve(provisional)) else { return nil }
            return await handler.browseProject()
        }
        model.onListProjects = { [weak self] query in
            guard let self, let handler = newTabPages[resolve(provisional)]?.handler ?? blankChatHandler?(resolve(provisional)) else { return [] }
            return await handler.listProjects(query)
        }
        model.onImportAndSync = { [weak self] in
            guard let self else { return }
            if let page = newTabPages[resolve(provisional)] { page.handler.importAndSync() }
            else { _ = actionRegistry?.perform("palette.welcomeChecklist", invocation: ActionInvocation(origin: .user)) }
        }
        model.onAppAction = { [weak self] id in
            guard let self else { return }
            newTabPages[resolve(provisional)]?.handler.action(id)
        }
        model.onCheckpointAvailability = { [weak self] _ in self?.publishCheckpointAvailability() }
        // A local session's folder is read by the local session host; the page refuses cloud sessions.
        if let git { model.onGit = { request in try await git.read(request) } }
        model.workspaceRoots = { [weak self] in
            guard let self else { return [] }
            return workspaceRoots(of: resolve(provisional))
        }
    }

    /// The local folders of the workspace that holds agent tab `key`: every local tab's cwd. The
    /// pane's relay limits each `cwd` and `path` the page sends to these (AcpmuxPathPolicy).
    func workspaceRoots(of key: String) -> [String] {
        guard let store = tabStores[key] else { return [] }
        let holds = { (workspace: WorkspaceModel) in
            workspace.screens.contains { $0.panes.contains { $0.tabs.contains { $0.id == key } } }
        }
        guard let workspace = store.workspaces.first(where: holds) else { return [] }
        var roots: [String] = []
        for tab in workspace.screens.flatMap({ $0.panes }).flatMap({ $0.tabs }) where tab.kind != .remoteTerminal {
            if let cwd = tab.cwd, !roots.contains(cwd) { roots.append(cwd) }
        }
        return roots
    }

    /// A pane view on this store's page and host, with the shared pushes.
    private func makeView(_ model: AgentPaneModel) -> AgentPaneView? {
        model.linkScheme = linkScheme
        guard let source, let view = AgentPaneView(model: model, source: source, renderRate: renderRate, pageHost: AgentPaneTunables.pageHost.value) else { return nil }
        view.customization = customization.current
        view.shortcuts = shortcuts
        view.previewFeatures = previewFeatures
        customization.start()
        return view
    }

    func existingView(_ key: String) -> AgentPaneView? { views[resolve(key)] }

    func newTabPage(_ key: String) -> (page: AgentPaneNewTab, handler: NewTabPageHandler)? { newTabPages[resolve(key)] }

    /// The tab still shows the new tab page (it has not become a chat).
    func isNewTabPage(_ key: String) -> Bool { newTabPages[resolve(key)] != nil }

    /// A new chat outside any pane (onboarding's first task), on the same
    /// daemon and page as the tabs. The caller owns it and closes it.
    func standaloneView(seed: AgentPaneSeed) -> AgentPaneView? {
        guard let view = makeView(AgentPaneModel(host: host, seed: AgentPaneSeedSource(seed))) else { return nil }
        standaloneViews.add(view)
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
        let available = checkpointFocusTab.flatMap { views[resolve($0)] }?.model.checkpointAvailable == true
        var next = registry.context
        if available { next.insert(.checkpointCaptureAvailable) }
        else { next.remove(.checkpointCaptureAvailable) }
        if next != registry.context { registry.context = next }
    }

    func stopCustomizationWhenUnused() {
        if views.isEmpty, standaloneViews.allObjects.isEmpty { customization.stop() }
    }
}

/// A store-committed agent chat tab: its tab id (`TabModel.id`) and surface.
struct AgentTabCreated: Sendable, Equatable {
    var key: String
    var surface: SurfaceID
}

/// What the store answered a session bind.
enum AgentSessionBindOutcome: Equatable {
    case taken
    /// Another device changed the tab's chat first (`conversation_tab.session_conflict`).
    case conflict
    /// The bind did not reach the store or failed otherwise.
    case failed
}

extension AgentTabStore {
    /// `name` without control characters, cut to 255 bytes on a character boundary; nil when empty.
    static func displayName(_ name: String) -> String? {
        var result = ""
        for character in name where !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            guard result.utf8.count + String(character).utf8.count <= 255 else { break }
            result.append(character)
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
