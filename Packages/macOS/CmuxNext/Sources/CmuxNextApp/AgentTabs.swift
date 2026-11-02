import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFloating
import CmuxNextHomeEngine
import CmuxNextRemote
import CmuxNextSettings
import CmuxNextTabs
import Observation

/// The pane views of agent chat tabs (the React acpmux pane, CmuxNextAgentPane).
///
/// An agent chat tab is a workspace store tab: a `conversation` tab whose source is an acpmux
/// session (`agent-session-tabs-v1`, cmux-tui/spec/commands.md new-conversation-tab). The store owns which
/// pane lists it, its order, and its session; it restores it after relaunch (R138) and moves,
/// splits and closes it like any tab. This type owns only client view state, keyed by tab id
/// (`TabModel.id`): the page views, a new chat's seed, the new tab page, link and turn requests.
/// One acpmux host is shared by every tab, so opening several at once starts one daemon.
final class AgentTabStore {
    let host: any AgentPaneHostProviding
    /// The app-wide objects every agent pane view shares (``AgentPaneShared``: the made-ahead open panel, the posting-process table).
    private let paneShared: AgentPaneShared
    /// The page every agent tab loads: the bundled file, or in Debug builds
    /// the dev server `CMUX_NEXT_AGENT_PANE_DEV_URL` names (nil only when the
    /// bundled page is missing).
    private let source: AgentPaneSource?
    /// Adaptive, or in Debug builds fixed by `CMUX_NEXT_AGENT_PANE_FULL_RATE`
    /// (`1` full, `0` capped) for measuring either rate.
    private let renderRate: AgentPaneRenderRate
    /// `~/.config/cmux/agent-pane/` hot reload, watched while any agent tab
    /// has a view.
    let customization: AgentPaneCustomizationWatcher
    /// The store record of agent tab `key` and the tree that lists it; nil for any other tab
    /// (AppServices looks in every machine's tree).
    var lookup: @MainActor (String) -> (record: AgentSessionRef, store: DaemonStore)? = { _ in nil }
    /// The pane holding tab `key` and its daemon (New side chat opens its fork there first).
    var locate: @MainActor (String) -> (pane: PaneID, daemon: DaemonService)? = { _ in nil }
    /// The right column beside the pane holding chat tab `key`, as ``RightColumnPlacement`` reads it (``LinkOpener/rightColumn(beside:)``).
    var rightColumn: @MainActor (String) -> RightColumnPlacement.Column = { _ in RightColumnPlacement.Column() }
    /// Runs an open on the right of chat tab `chat` in its turn (``RightColumnTurns``); unwired: at once.
    var serially: @MainActor (_ chat: String, _ turn: @escaping RightColumnTurns.Turn) -> Bool = { _, turn in turn({}); return true }
    /// A right-column pane by its ``RightColumnPlacement/Column`` key (a layout pane id) and its daemon, looked
    /// up only in the workspace that holds chat tab `chat`, where ``rightColumn`` measured it: a layout pane id
    /// (`pane:<handle>` without a resource id) is not unique across daemons or workspaces.
    var locatePane: @MainActor (_ chat: String, _ key: String) -> (pane: PaneID, daemon: DaemonService)? = { _, _ in nil }
    /// Moves fork tab `key`, opened in chat tab `chat`'s pane, to a new strip column (`left`: before the chat's) or, nil, a new row.
    var placeFork: @MainActor (_ key: String, _ chat: String, _ left: Bool?) -> Void = { _, _, _ in }
    /// Selects tab `key` in its pane without moving keyboard focus (an unfocused subagent tab).
    var selectInPane: @MainActor (String) -> Void = { _ in }
    /// Main pane layout (``MainPaneLayout``): opens what chat tab `chat` opens beside it (through
    /// `open`, focused with `focus`) in the column on the chat's right, then `created` and
    /// `finished` as ``openBeside`` calls them. Nil when the chat is not its screen's main pane:
    /// the caller places the tab itself.
    var openInMainPane: @MainActor (_ chat: String, _ focus: Bool, _ open: (PaneID, DaemonService) throws -> AgentTabPending,
                                    _ created: (@MainActor (String) -> Void)?, _ finished: (@MainActor (Bool) -> Void)?) -> Bool? = { _, _, _, _, _ in nil }
    /// Every agent tab the trees list, with its record.
    var listTabs: @MainActor () -> [(key: String, record: AgentSessionRef)] = { [] }
    /// Creates the store tab with idempotency key `key` (AppServices: `new-conversation-tab` on
    /// the pane's daemon), in a new split of the pane with `split`. Returns it and the daemon event sequence read after the reply (nil
    /// when the connection ended: the next snapshot holds the tab).
    var create: @MainActor (_ pane: PaneID, _ daemon: DaemonService, _ record: AgentSessionRef, _ key: String,
                            _ transaction: ClientTransactionID, _ split: ConversationTabSplit?) async throws
        -> (created: AgentTabCreated, sequence: UInt64?) = { _, _, _, _, _, _ in throw DaemonError.notConnected }
    /// Moves a pane's selection from provisional tab `provisional` to the created tab's surface,
    /// where the pane still selects it (AppServices: every pane controller).
    var moveSelection: @MainActor (_ provisional: String, _ surface: SurfaceID) -> Void = { _, _ in }
    /// The pane host for agent tab `key` when its session runs on another machine whose session
    /// daemon serves `agent-session-attach-v1` (AppServices); nil keeps the "runs on" notice.
    var remoteHost: @MainActor (String) -> (any AgentPaneHostProviding)? = { _ in nil }
    /// The acpmux turn states and sub-session links (`startedBy`) the app's watches mirror: a chat's
    /// page opens only sessions of its own family (``AgentPaneHeaderHooks/isFamily``).
    var turns: AgentTurnStateStore = .shared
    var chiefHost: String?, chiefPaneHost: (any AgentPaneHostProviding)?, localSessionHost: (any AgentPaneHostProviding)? // ChiefHomeAcpmux
    /// This Mac's other Chief homes, for tabs made under one of them (#25262); nil in tests.
    var chiefHomes: ChiefHomeDirectory?
    /// Whether `daemon` holds agent session tabs (`agent-session-tabs-v1`).
    var holdsTabs: @MainActor (DaemonService) -> Bool = { $0.supports(DaemonCapability.agentSessionTabs.rawValue) }
    /// Sets tab `surface`'s session (and harness) by compare-and-swap from `expected` (AppServices: `bind-conversation-tab-session`
    /// on the tab's daemon): the store's answer and, when it took it, the daemon event sequence read after the reply (nil: connection ended).
    var bind: @MainActor (_ key: String, _ surface: SurfaceID, _ expected: String?, _ session: String, _ harness: String?) async
        -> (outcome: AgentSessionBindOutcome, sequence: UInt64?) = { _, _, _, _, _ in (.taken, nil) }
    /// Whether `daemon` is connected now: a disconnected owner refuses changes, nothing queues.
    var reachable: @MainActor (DaemonService) -> Bool = { $0.connection != nil }
    /// Tab `key`'s daemon: where its workspace's agent folder is saved and where the store answers
    /// where its new chats start (cx-9aps). Nil while the tab is not found.
    var daemonForTab: @MainActor (_ key: String) -> DaemonService? = { _ in nil }
    /// Reads the Mac-local repository catalog through the local cmux daemon frame protocol.
    var cloudRepositoryLocal: @MainActor () async throws -> Data = {
        throw DaemonError.notConnected
    }
    /// The daemon whose tree lists `tab`, by the record's identity (MachineRegistry.daemon(forTab:)):
    /// it reads no tab list, so a pane snapshot that asks hears no other pane's tabs. Nil in tests.
    var daemonListing: @MainActor (TabModel) -> DaemonService? = { _ in nil }
    /// This Mac's name for other Macs that show its tabs ("This chat runs on <name>"): ≤255 bytes, no control characters.
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
    /// The machine link each pane's composer strip shows, and the reconnect a chat's use of a down machine runs.
    let machineLink = AgentPaneMachineLink()
    /// Agent tabs whose view waits for the launch's first pane content (`deferAtLaunch`).
    var launchDeferred: Set<String> = []
    /// The tabs' pages from the last quit, drawn at launch (`AgentPaneLaunchImages`).
    var launchImages = AgentPaneLaunchImages(directory: nil)
    /// New chats' typed text from before they have a session, kept across a relaunch (cx-z5vd).
    var unsentDrafts = AgentUnsentDrafts(file: nil, files: AgentPaneStateFiles())
    /// "This chat runs on <machine>" for tabs whose session another Mac's acpmux runs.
    var notices: [String: AgentTabElsewhereView] = [:]
    /// A provisional tab's id -> the store's id once the creation answered (``AgentTabStore/rekey(_:to:)``): one page.
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
    /// The prewarmed New Tab page, for a first page that has no view yet (NewTabSparePool).
    var takeSpare: (() -> AgentPaneView?)?
    /// The prewarmed page once it is connected and drawn, for a tab opening an existing chat of
    /// this Mac (``SpareSessionAdoption``); nil leaves the spare in the pool.
    var takeConnectedSpare: (() -> AgentPaneView?)?
    /// Whether this Mac's Chief home keeps session `session` (an older subagent tab recorded with
    /// this Mac's host attaches there, ``AcpmuxChiefSessionRouter``): the spare is connected to
    /// this Mac's acpmux, so such a chat gets its own page.
    var chiefKeepsSession: @MainActor (String) -> Bool = { _ in false }
    /// Tab `key` got a page (built or adopted from the spare), drawn or not: a page built while its
    /// tab does not draw starts its hidden clock (`AgentPageHibernation.pageBuilt`).
    var onPageBuilt: ((String) -> Void)?
    /// Every page is asked what it holds now (true), or that ended (false) (`AgentPageHibernation.holdAwake`).
    var onCollectingPages: ((Bool) -> Void)?
    /// Closed pages leave the view tree at once; their teardown waits (R81).
    let retirer = AgentPageRetirer()
    /// The session each tab's page reported, ahead of the store's echo of the bind and across a
    /// web content crash or a view rebuilt after the tab was released.
    var sessions: [String: String] = [:]
    /// A tab's page now shows another acpmux session (its first, or a `chat.select` switch).
    var onTabSession: @MainActor () -> Void = {}
    /// A new chat's seed on another machine (its folder and harness start it there, its draft and
    /// prompt reach the page), by tab (``startRemoteChat(_:machine:endpoint:)``).
    var remoteSeeds: [String: AgentPaneSeedSource] = [:]
    /// New chats on another machine whose store tab is still being created: they start once it is.
    var remoteCreations: [String: AgentTabPending] = [:]
    /// Provisional id -> store id of new chats on another machine, kept while the tab lives.
    var remoteAliases: [String: String] = [:]
    /// Starts in flight on another machine, so a reconnecting page waits for the same one.
    var remoteStarts: [String: Task<AgentTabRemoteStart.Started, any Error>] = [:]
    /// The folder a new chat on another machine starts in when its seed names none: a folder of
    /// its workspace on that machine (AppServices).
    var remoteFolder: (@MainActor (String) -> String?)?
    /// The folders of every workspace on the machine of tab `key` (its terminals' folders there),
    /// for the project list of a chat on that machine.
    var remoteFolders: (@MainActor (String) -> [String])?
    /// The folders the machine of tab `key` lists itself (`agent-session-folders`: its work folder,
    /// then the folders under it), for the same project list; none from an older daemon.
    var remoteMachineFolders: (@MainActor (String) async -> [String])?
    /// Share with Me on the refused start of tab `key`'s chat: grants the signed-in person chats on
    /// its Cloud machine (``CloudMachineShare/shareWithMe(_:cloud:)``).
    var shareMachineWithMe: (@MainActor (String) async -> AgentPaneMachineShare)?
    /// The display name of a remote daemon's machine, recorded on the tabs of its new chats.
    var remoteMachineName: @MainActor (DaemonService) -> String? = { _ in nil }
    /// Shared conversion and project actions for a direct blank chat, without a chooser page.
    var blankChatHandler: ((String) -> NewTabPageHandler?)?
    /// Each agent session's own avatar (Set Avatar… in the chat's ⋯ menu).
    var agentAvatars: AgentAvatars?
    /// A Chief's name and avatar as the sidebar shows them, by participant id (`chief.face`).
    var chiefFace: (@MainActor (String) async -> [String: String])?
    /// Opens a redeemed Run attempt's terminal, owned by an enrolled worker daemon, in the tab's pane.
    var runAttach: (@MainActor (_ key: String, _ request: AgentPaneRunAttach) async throws -> Void)?
    /// The New Tab page a new workspace's first tab shows, starting in the given folder.
    /// `(cwd, beside)`: `beside` is the tab whose machine the page opens on (nil: this Mac).
    var firstPageNewTab: ((String?, String?) -> (page: AgentPaneNewTab, handler: NewTabPageHandler)?)?

    /// Tabs opened as the chooser page, and the actions for their selected kind.
    var newTabPages: [String: (page: AgentPaneNewTab, handler: NewTabPageHandler)] = [:] {
        didSet { pageTabs.set(Set(newTabPages.keys)) }
    }
    /// The ids in ``newTabPages``, observed: the strip titles those tabs "New Tab".
    let pageTabs = NewTabPageIDs()
    /// What each new chat inherits from the tab it was opened from, until
    /// its view reads it.
    var seeds: [String: AgentPaneSeedSource] = [:]
    /// A new workspace's chat seed until its tab is known (`seedFirstChat`).
    var firstChats: [WorkspaceHandle: AgentPaneSeedSource] = [:]
    /// The key-hold token of a new workspace's first New Tab page (Cmd-N, NewTabInputCoordinator),
    /// until its create returned: the page made for that workspace's tab, and only it, carries it.
    var firstPageTokens: [WorkspaceHandle: String] = [:]
    /// A first page took a key-hold token (the hold then waits for that page's readiness).
    var onFirstPageToken: ((String) -> Void)?
    /// The tab resuming each outside chat (`harness:agentSessionId`), so
    /// picking the same chat again shows that tab instead of a second one.
    private static let adoptionsDefaultsKey = "cmux.agent-tabs.outside-adoptions"
    private let defaults: UserDefaults
    /// The tab resuming each outside chat (`harness:agentSessionId`). Persisted
    /// so a restored tab remains the link target after relaunch.
    var adoptions: [String: String] = [:] {
        didSet {
            guard oldValue != adoptions else { return }
            if let data = try? JSONEncoder().encode(adoptions) {
                defaults.set(data, forKey: Self.adoptionsDefaultsKey)
            }
        }
    }
    /// The app shortcuts every agent page shows, kept current on rebinds.
    private var shortcuts = AgentPaneShortcuts()
    private var shortcutObservation: Task<Void, Never>?
    /// `labs.previewFeatures` and `agentPane.editedFiles.*`, pushed to every page like the shortcuts.
    private let pageSettings = AgentPanePageSettings()
    /// The one Read aloud voice every chat page speaks through, and Stop Reading Aloud stops.
    let readAloud = AgentPaneReadAloud()
    /// The Cloud machines each page's environment picker lists (`cloudMachine.*`); the app's peer approver for every host and page.
    let cloudMachines = AgentPaneCloudMachines()
    /// The iPhone host's Remote Control switch, which every page's Session Info shows (set by the wiring).
    var remoteControl: AgentPaneRemoteControl?
    let peerApprover: AgentPanePeerApprover?
    /// The device chats every page's New Tab cards show (``AgentPageChats``).
    let pageChats = AgentPageChats()
    weak var actionRegistry: ActionRegistry?
    var checkpointFocusTab: String?
    /// This build's URL scheme, handed to every page for the links it copies.
    private let linkScheme: String?
    /// Tabs a `cmux://session/<id>` link opened: their page refuses a
    /// session the daemon does not have instead of falling back.
    var linkedSessions: Set<String> = []
    /// A link's turn for a tab whose view is not made yet.
    var pendingTurns: [String: String] = [:]
    /// What each released chat page held that acpmux does not (``AgentPageHibernation``), for
    /// the page built when its tab shows again.
    var wakeStates: [String: AgentPaneWakeState] = [:]
    /// What the chat pages held at the last quit, for each tab's first page at launch (``AgentPaneRelaunchWake``).
    var relaunchWake = AgentPaneRelaunchWake(file: nil)
    /// What every chat holds for the next launch (the quit's window step). Pages that froze while
    /// hidden thaw first and stay awake until it is collected: a frozen page answers nothing.
    func relaunchWakeStates() async -> [String: AgentPaneWakeState] {
        onCollectingPages?(true)
        defer { onCollectingPages?(false) }
        return await relaunchWake.collect(held: wakeStates, pages: views.map { (resolve($0.key), $0.value) }, live: isAgentTab)
    }
    /// The git link of tab `key`: the session host of the tab's own machine (AgentPaneGitReads.swift),
    /// so a Cloud or SSH chat reads its folder there; nil answers the page `native.not_connected`. Move to Floating Chat puts a session in Start Agent's panel.
    /// The upload for a chat tab's dropped or pasted files, nil when it takes none (``CloudUploads``).
    var uploader: (@MainActor (_ tab: String) -> AgentPaneUploader?)?
    var uploadStager: (@MainActor (_ tab: String) -> AgentPaneUploadStager?)?
    /// Whether a chat tab's (or its New Tab page's) dropped or pasted files go as their paths on this
    /// Mac (``AgentPaneModel/onLocalPaths``); nil: never.
    var localPaths: (@MainActor (_ tab: String) -> Bool)?
    /// A background task's terminal beside chat tab `chat` (``AgentProcessTerminal``); false when none opened.
    var openProcess: (@MainActor (_ chat: String, _ viewer: AgentPaneProcessViewer) -> Bool)?
    var cloudCredentialTransfer: (@MainActor (_ chat: String, _ request: AgentPaneCloudCredentialTransferRequest) async -> Bool)?
    /// Session `session` on chat tab `chat`'s right as a link opens (``LinkOpener``, `layout.linkPlacement`):
    /// a tab in the pane there, else a new split, focused; false when nothing opened.
    var openRight: (@MainActor (_ chat: String, _ session: String) -> Bool)?
    /// The header's Terminal or Browser on chat tab `chat`'s right (``AgentChatTabActions/openTool``).
    var openTool: (@MainActor (_ chat: String, _ kind: RightColumnPlacement.Kind, _ cwd: String?) -> Bool)?
    var gitLink: (@MainActor (String) -> AgentPaneGitLink?)?, openFiles: (@MainActor (_ chat: String, _ folder: String, _ target: String?) -> Void)?, moveToFloatingChat: (@MainActor (String) -> Bool)?
    /// Cloud destinations exposed to a started chat's title menu. The page receives only the
    /// current live list; it never invents or persists machine ids.
    var machineTargets: @MainActor () -> [AgentPaneMoveTarget] = { [] }
    /// Runs the existing CloudMove action for a validated target machine.
    var moveAgentToMachine: @MainActor (_ tab: String, _ machine: String) -> Bool = { _, _ in false }

    /// `settings`, when given, is followed for the page settings (``AgentPanePageSettings``); else from `AppServices.settings`.
    /// `daemons` and `updates` are the app's (`AppServices`); a test's store has its own and updates no other machine.
    init(build: BuildIdentity?, registry: ActionRegistry, environment: [String: String] = ProcessInfo.processInfo.environment,
         showcase: Bool = false, linkScheme: String? = nil, settings: SettingsController? = nil, paneShared: AgentPaneShared = AgentPaneShared(), defaults: UserDefaults = .standard,
         daemons: AcpmuxLocalDaemons = AcpmuxLocalDaemons(), updates: DaemonUpdates? = nil, peerApprover: AgentPanePeerApprover? = nil) {
        (self.defaults, self.peerApprover) = (defaults, peerApprover)
        if let data = defaults.data(forKey: Self.adoptionsDefaultsKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            adoptions = saved
        }
        self.paneShared = paneShared
        actionRegistry = registry
        self.linkScheme = linkScheme
        let (resolvedSource, resolvedHost) = AgentTabPaneSource.resolvePane(build: build, environment: environment, showcase: showcase, daemons: daemons, peerApprover: peerApprover)
        host = resolvedHost
        // Start acpmux while the first pane is loading. The page still owns
        // the authenticated WebSocket handshake and session selection. Then
        // other machines' daemons get this build, in the background (DaemonUpdates).
        Task {
            try? await resolvedHost.prewarm()
            guard resolvedHost is AcpmuxHost, let updates else { return }
            let installer = RemoteInstaller(paths: .standard(bundleID: Bundle.main.bundleIdentifier))
            updates.startOnce(build: build, environment: environment) { try await installer.download(artifact: $0, nextTo: $1) }
        }
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
            for await value in ObservationStream({ AgentPaneShortcuts.read(registry) }) {
                guard let self else { return }
                shortcuts = value
                for view in views.values { view.shortcuts = value }
                for view in standaloneViews.allObjects { view.shortcuts = value }
            }
        }
        if let settings { follow(settings) }
    }

    /// Follows the page settings in cmux.json (``AgentPanePageSettings``).
    func follow(_ settings: SettingsController) {
        pageSettings.follow(settings) { [weak self] in
            guard let self else { return }
            for view in views.values { pageSettings.apply(to: view) }
            for view in standaloneViews.allObjects { pageSettings.apply(to: view) }
        }
    }

    /// True when `key` names an agent chat tab in a tree.
    func isAgentTab(_ key: String) -> Bool { lookup(key) != nil }

    /// True when a pane of `daemon` can get a new agent chat tab: this build has the page, this
    /// Mac has an install id, and the daemon holds agent session tabs.
    func canHost(on daemon: DaemonService) -> Bool { canHostChat && localHost != nil && holdsTabs(daemon) }

    /// The tab showing acpmux session `session` of `host` (default this Mac), if any.
    func tab(showing session: String, host: String? = nil) -> String? {
        let host = host ?? localHost
        return listTabs().first { $0.record.host == host && (sessions[$0.key] ?? $0.record.session) == session }?.key
    }

    /// The acpmux session agent tab `key` shows; nil for a new chat.
    func session(of key: String) -> String? {
        let key = resolve(key)
        return sessions[key] ?? lookup(key)?.record.session
    }

    /// The store's id of `key` (a provisional id after its creation answered).
    func resolve(_ key: String) -> String { aliases[key] ?? key }

    /// ``resolve(_:)`` for a new chat on another machine: its page's host keeps the provisional id
    /// it was made with, and the start runs at the first send, after the tree settled and dropped
    /// the provisional alias (cx-k21v: a remote New Tab page's send failed with unknown_tab).
    func resolveRemote(_ key: String) -> String { aliases[key] ?? remoteAliases[key] ?? key }

    /// The ``revealTurn(_:in:)`` value that scrolls to and marks message `id`, the harness message
    /// id an `agent/<harness>/<session>?message=<id>` link carries (the page's `MESSAGE_REVEAL`,
    /// webviews/src/agent-session/acpmux/links.ts). A message this machine's transcript does not
    /// have leaves the view where it is.
    static func messageReveal(_ id: String) -> String { "message:" + id }

    /// Scrolls tab `key`'s transcript to `turn` (a `#turn-<turnId>` link):
    /// through its page, or with the handshake of a page not made yet.
    func revealTurn(_ turn: String, in key: String) {
        let key = resolve(key)
        if let view = views[key] { view.revealTurn(turn) } else { pendingTurns[key] = turn }
    }

    /// The tab's pane view, made on first show. A tab whose session runs on another machine is
    /// carried by that tab's own session daemon (``remoteHost``); nil when it cannot be (the
    /// pane then shows the "runs on" notice).
    func view(for key: String) -> AgentPaneView? {
        let key = resolve(key)
        if let view = views[key] { return view }
        guard let (record, store) = lookup(key) else { return nil }
        let kind = AgentPaneHostKind(record, localHost: localHost, chiefHost: chiefHost, listedHere: daemonForTab(key)?.isLocal != false)
        // A Chief subagent runs on this Mac too, in the Chief home's acpmux.
        let local = kind != .remote
        // A tab recorded for this Mac in another machine's tree with no chat yet (saved before
        // cx-k21v): this Mac's New Tab page or chat there would start in this Mac's acpmux.
        if kind == .local, (sessions[key] ?? record.session) == nil, daemonForTab(key)?.isLocal == false {
            let machine = daemonForTab(key).flatMap { remoteMachineName($0) } ?? ""
            let refused = AgentTabRefusedHost(refusal: AgentRemoteStartRefusal(code: AgentRemoteStartRefusal.hostMismatchCode, machine: machine))
            let model = AgentPaneModel(host: refused, allowsTabConversion: false)
            // Its folder tools never act on this Mac either (cx-k21v).
            (model.remoteChat, model.neverPooled) = (true, true)
            guard let view = makeView(model) else { return nil }
            views[key] = view
            track(key, in: store)
            return view
        }
        // A new chat on another machine starts there from its seed (``startRemoteChat``): the
        // folder and harness start it, the draft and prompt reach its page.
        let seed = local || record.host.hasPrefix(AgentTabRemoteStart.registryPrefix)
            ? (seeds.removeValue(forKey: key) ?? firstChatSeed(of: key, in: store) ?? unsentDrafts.seed(for: key, session: sessions[key] ?? record.session, local: local)) : nil
        if !local, let seed { remoteSeeds[key] = seed }
        guard let paneHost = kind == .local ? (localSessionHost ?? host) : kind == .chief ? chiefTabHost(record.host) : remoteHost(key) else {
            if !local, let seed { seeds[key] = seed }
            return nil
        }
        // A tab this run did not open and that has no chat yet is a New Tab page the store
        // restored after a relaunch: it opens as the page again, not as an empty chat. A seeded
        // tab is a chat this run opened (New Agent Chat's workspace, listed by the tree before
        // new-conversation-tab replied): it stays the chat, never the page (cx-vurv).
        if local, seed == nil, newTabPages[key] == nil, tabStores[key] == nil, (sessions[key] ?? record.session) == nil,
           !linkedSessions.contains(key) {
            newTabPages[key] = firstPage(cwd: nil, token: firstPageToken(of: key, in: store))
        }
        // A New Tab page made now (Cmd-N's first page, a restored page) adopts the prewarmed spare
        // when there is one: no cold load and React mount on the open path (cx-ec99).
        // (Its folder rides on the page context, `newTab.cwd`; a first page's seed holds only that.)
        // A page with a kept composer (``wakeStates``) gets its own page: the spare's handshake is past.
        if local, kind == .local, sessions[key] == nil, record.session == nil, let newTab = newTabPages[key],
           seed?.holdsOnlyFolder ?? true, wakeStates[key] == nil, !relaunchWake.mayHold(key), let spare = takeSpare?() {
            adoptSpare(spare, key: key, page: newTab.page)
            track(key, in: store)
            onPageBuilt?(key)
            return spare
        }
        // An existing chat of this Mac (a sidebar click, Open in Tab, a subagent's pane) adopts the
        // spare too: it is loaded and connected, and switches to the chat in place.
        if let session = SpareSessionAdoption.session(local: local, kind: kind, session: sessions[key] ?? record.session,
                                                      newTabPage: newTabPages[key] != nil, seeded: seed != nil,
                                                      wake: wakeStates[key] != nil || relaunchWake.mayHold(key),
                                                      chiefKeeps: chiefKeepsSession),
           let spare = takeConnectedSpare?(), adoptSpare(spare, key: key, session: session, revealTurn: pendingTurns.removeValue(forKey: key)) {
            track(key, in: store)
            onPageBuilt?(key)
            return spare
        }
        let model = AgentPaneModel(
            host: paneHost,
            sessionId: sessions[key] ?? record.session,
            seed: seed,
            // A new chat this app opened on another machine shows the same New Tab page (cx-k21v).
            newTab: local || record.host.hasPrefix(AgentTabRemoteStart.registryPrefix) ? newTabPages[key]?.page : nil,
            allowsTabConversion: local
        )
        model.pendingRevealTurn = pendingTurns.removeValue(forKey: key)
        model.pendingWake = wakeStates.removeValue(forKey: key)
        relaunchWake.hand(key, to: model)
        model.onCloudRepositoryLocal = cloudRepositoryLocal
        wire(model, key: key)
        // A page of another machine's chat is never pooled as this Mac's spare (its host is that machine's).
        if !local {
            model.neverPooled = true
            model.remoteChat = true
            model.onListRemoteProjects = { [weak self] query in
                guard let self else { return [] }
                let listed = remoteFolders?(resolveRemote(key)) ?? []
                let machine = await remoteMachineFolders?(resolveRemote(key)) ?? []
                let folders = AgentTabRemoteStart.folders(listed: listed, machine: machine)
                guard let query = query?.lowercased(), !query.isEmpty else { return folders }
                return folders.filter { $0.lowercased().contains(query) }
            }
            model.onShareMachineWithMe = { [weak self] in
                guard let self, let shareMachineWithMe else { return .refused(code: "unavailable", message: CloudShareStrings.notCloudMachine) }
                return await shareMachineWithMe(resolveRemote(key))
            }
        }
        guard let view = makeView(model) else {
            // The next page made for the tab still gets it.
            if let wake = model.pendingWake { wakeStates[key] = wake }
            return nil
        }
        views[key] = view
        track(key, in: store)
        onPageBuilt?(key)
        return view
    }

    /// A prewarmed new tab page (NewTabSparePool): loaded, rendered and
    /// connected before any tab exists; ``open(in:of:session:seed:newTab:spare:linked:adopt:idempotencyKey:)`` adopts it.
    func makeSpare(_ page: AgentPaneNewTab) -> AgentPaneView? {
        guard let view = makeView(AgentPaneModel(host: host, newTab: page)) else { return nil }
        standaloneViews.add(view)
        return view
    }

    /// Tab `key`'s callbacks on its page's model. Each resolves the tab's current id when it
    /// runs, so a page made under a provisional id keeps working under the store's.
    func wire(_ model: AgentPaneModel, key provisional: String) {
        model.onSessionChange = { [weak self] session in
            guard let self else { return }
            let key = resolve(provisional)
            newTabPages[key] = nil
            views[key]?.applyTheme() // now the agent chat surface (R55)
            // The first session is the outside chat's resume; a later switch shows another chat,
            // so the tab no longer answers for the outside chat it adopted (cmux://agent links).
            if let shown = sessions[key], shown != session { adoptions = adoptions.filter { $0.value != key } }
            let switched = sessions[key] != session
            sessions[key] = session
            if switched { onTabSession() }
            // Another machine's store keeps its own record of the session: its daemon bound it at
            // the start, so no bind goes from here (cx-k21v). Its git reads go there (``gitLink``).
            if bindsHere(key) { sendSession(session, for: key) }
        }
        model.onSessionHarness = { [weak self] session in self.map { $0.sendSession(session, for: $0.resolve(provisional)) } }
        model.onCloudCredentialTransfer = { [weak self, weak model] request in
            guard let self, let model, model.sessionId == request.sessionID,
                  let record = self.lookup(self.resolve(provisional))?.record,
                  AgentPaneCloudCredentialTransferRequest.Provider(harnessID: record.harness) == request.provider,
                  let transfer = self.cloudCredentialTransfer else { return false }
            return await transfer(self.resolve(provisional), request)
        }
        unsentDrafts.wire(model) { [weak self] in self?.resolve(provisional) ?? provisional }
        model.onOpenTab = { [weak self] request in
            BenchSpans.mark("bridge.tab.open")
            guard let self else { return }
            let key = resolve(provisional)
            (newTabPages[key]?.handler ?? blankChatHandler?(key))?.open(key, request)
        }
        model.onRunAttach = { [weak self] request in guard let self, let runAttach else { throw AgentPaneHostError.daemonStopped }; try await runAttach(resolve(provisional), request) }
        model.onTypeAhead = { [weak self] text in self.map { $0.pageHandler(provisional)?.typeAhead($0.resolve(provisional), text) } }
        model.onNewTabInputReady = { [weak self] token in self.map { $0.newTabPages[$0.resolve(provisional)]?.handler.inputReady($0.resolve(provisional), token) } }
        model.onRememberNewTab = { [weak self, weak model] pick in
            if let model { AgentPaneNewTabFrame.shared.modelChanged(pick, by: model) }
            self?.pageHandler(provisional)?.remember(pick)
        }
        model.onEditNewTab = { [weak self] edit in self?.pageHandler(provisional)?.edit(edit) }
        model.onJump = { [weak self] target, id in self?.newTabPage(provisional)?.handler.jump(target, id) }
        model.onEditShortcut = { [weak self] kind in self?.newTabPage(provisional)?.handler.editShortcut(kind) }
        model.machineLink = machineLink
        model.onRunAction = { [weak self] id, arguments in
            guard let self else { return false }
            // On this tab's pane: the New Tab page opens beside the tab that asked. Reconnect runs
            // on the machine this tab's chat runs on, resolved here: the page never names a machine.
            let target: ActionTargetRef
            if id == "machine.reconnect" {
                guard let machine = remoteMachineID(of: provisional) else { return false }
                target = ActionTargetRef(kind: .machine, id: machine)
            } else {
                target = ActionTargetRef(kind: .tab, id: resolve(provisional))
            }
            return actionRegistry?.perform(ActionID(rawValue: id), invocation: ActionInvocation(target: target, arguments: arguments.mapValues(ActionValue.string), origin: .user)) ?? false
        }
        wireHeader(model, key: provisional)
        model.onBrowseProject = { [weak self] in
            guard let self, let handler = newTabPages[resolve(provisional)]?.handler ?? blankChatHandler?(resolve(provisional)) else { return nil }
            return await handler.browseProject()
        }
        model.onListProjects = { [weak self] query in
            guard let self, let handler = newTabPages[resolve(provisional)]?.handler ?? blankChatHandler?(resolve(provisional)) else { return [] }
            return await handler.listProjects(query)
        }
        model.onOpenChat = { [weak self] key in
            guard let self else { return }
            // From a New Tab page the chat takes that tab; elsewhere it opens through Open Chat.
            let page = resolve(provisional)
            if isNewTabPage(page), let openHere = pageChats.openHere { openHere(key, page) } else { pageChats.open?(key) }
        }
        model.onOpenChatInTerminal = { [weak self] key in self?.pageChats.openInTerminal?(key) }
        model.onWatchChat = { [weak self] key in self?.pageChats.watch?(key) }
        model.onChatsPage = { [weak self] query in
            let answer = await self?.pageChats.page?(query)
            // A New Tab page on screen gives the frame of the list it draws now.
            if let self, let view = views[resolve(provisional)], view.model.newTab != nil, let host = view.superview { AgentPaneNewTabFrame.shared.capture(view, in: host) }
            return answer
        }
        model.onAppAction = { [weak self] id in
            guard let self else { return }
            newTabPages[resolve(provisional)]?.handler.action(id)
        }
        model.onCheckpointAvailability = { [weak self] _ in self?.publishCheckpointAvailability() }
        model.onGit = { [weak self] request in
            guard let link = self?.gitLink?(self?.resolve(provisional) ?? provisional) else { throw AgentPaneGitFailure.notConnected }
            return try await link.read(request)
        }
        // Commits and pushes run on the session's machine; the model refuses a session whose folder is not local.
        model.onGitWrite = { [weak self] request, cwd in
            guard let link = self?.gitLink?(self?.resolve(provisional) ?? provisional) else { throw AgentPaneGitFailure.notConnected }
            return try await link.write(request, in: cwd)
        }
        wireAgentFolder(model, key: provisional)
        wireAgentReply(model, key: provisional)
        model.onUpload = { [weak self] in
            guard let self else { return nil }
            return uploader?(resolve(provisional))
        }
        model.onUploadStage = { [weak self] in
            guard let self else { return nil }
            return uploadStager?(resolve(provisional))
        }
        model.onLocalPaths = { [weak self] in
            guard let self else { return false }
            return localPaths?(resolve(provisional)) ?? false
        }
    }

    /// A pane view on this store's page and host, with the shared pushes.
    private func makeView(_ model: AgentPaneModel) -> AgentPaneView? {
        AgentPaneNewTabFrame.shared.pageMade(model)
        model.linkScheme = linkScheme
        (model.readAloud, model.cloudMachines, model.remoteControl, model.transport.peerApprover) = (readAloud, cloudMachines, remoteControl, peerApprover)
        guard let source, let view = AgentPaneView(model: model, source: source, renderRate: renderRate, pageHost: AgentPaneTunables.pageHost.value || AgentPaneTunables.chromium.value, shared: paneShared) else { return nil }
        DebugTimings.markLaunch("agent_pane.view_created")
        view.customization = customization.current
        view.shortcuts = shortcuts
        pageSettings.apply(to: view)
        // A New Tab page draws its own first frame: no native loading mark (Lawrence 2026-10-10,
        // React-only New Tab). Chat panes keep it.
        if model.newTab != nil { view.showsLoadingState = false }
        pageChats.seed(view)
        wireAgentAvatars(model, view: view)
        model.onComposerSetting = { [weak pageSettings] path, show in try await pageSettings?.setComposer(path, show) }
        model.onDisplaySetting = { [weak pageSettings] path, value in try await pageSettings?.setDisplay(path, value) }
        customization.start()
        return view
    }

    func existingView(_ key: String) -> AgentPaneView? { views[resolve(key)] }

    func newTabPage(_ key: String) -> (page: AgentPaneNewTab, handler: NewTabPageHandler)? { newTabPages[resolve(key)] }
    /// The New Tab page's handler, else a chat tab's (a chat's picks are remembered too, cx-q5x6r).
    func pageHandler(_ key: String) -> NewTabPageHandler? { newTabPages[resolve(key)]?.handler ?? blankChatHandler?(resolve(key)) }

    /// The tab still shows the new tab page (it has not become a chat).
    func isNewTabPage(_ key: String) -> Bool { newTabPages[resolve(key)] != nil }

    /// A chat outside any pane (onboarding's first task, Start Agent's panel), new or on `session`,
    /// on the same daemon and page as the tabs. The caller owns it and closes it.
    func standaloneView(seed: AgentPaneSeed, session: String? = nil) -> AgentPaneView? {
        guard let view = makeView(AgentPaneModel(host: host, sessionId: session, seed: AgentPaneSeedSource(seed))) else { return nil }
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

    func stopCustomizationWhenUnused() { if views.isEmpty, standaloneViews.allObjects.isEmpty { customization.stop() } }
}
