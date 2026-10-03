import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDesign
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextBrowserImport
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextUpdater

/// Process-wide services the window controllers share. Model state is not
/// here: the daemon owns it, windows own their local state.
final class AppServices {
    let environment: AppEnvironment
    /// Each window's last sidebar, drawn before the daemon answers.
    let sidebarSnapshots: SidebarSnapshotStore
    /// Launch load-in by region; tests inject one with their own clock.
    let launchReveal: LaunchReveal
    /// Run marker, restart notice, crash reports (`debug.crashes`).
    let crashRecovery: CrashRecoveryService
    /// The local daemon. Cloud machines are in `machines`; code acting on a
    /// workspace, pane, or tab resolves its daemon through `machines`.
    let daemon = DaemonService()
    /// Agent panes' git reads on the local daemon (AgentPaneGitReads.swift).
    private(set) lazy var agentGit = AgentPaneGitLink(daemon: daemon)
    let machines: MachineRegistry
    /// The machine of the action being run, while its handler runs
    /// (`ActionRouting`); `activeDaemon` prefers it.
    var routedDaemon: DaemonService?
    /// Brings a window forward for a jump (`revealTab`, a `cmux://` link).
    /// Tests replace it to record the intent without ordering windows in.
    var showJumpWindow: @MainActor (NSWindow, WindowActivation.Intent) -> Void = { WindowActivation.show($0, $1) }
    /// The app's key window. Tests and `debug.key` replace it: a window
    /// only becomes key in a running, active app.
    var keyWindowSource: @MainActor () -> NSWindow? = { NSApp.keyWindow }
    private(set) var cloud: CloudService!
    /// The feed mirror (`FeedDO`), started once the cmux account is signed in.
    private(set) var feed: FeedService!
    /// SSH machines (Connect to Machine…).
    private(set) var ssh: SSHService!
    /// Phone access; started by the account layer once signed in.
    let mobile = MobileHostService()
    let registry = ActionRegistry.standard()
    /// Sparkle updates (release builds) or read-only feed probes (DEV).
    let updater = UpdaterService()
    private(set) var updateSheet: UpdateSheetController!
    /// cmux.json controller; set by `AppDelegate` once it starts.
    var settings: SettingsController?
    /// Writes the palette shortcut recorder's edits (the recorder holds it weakly).
    var paletteShortcutEditor: PaletteShortcutEditor?
    private(set) var cache: TabContentCache!
    private(set) var windows: WindowManager!
    private(set) var dragSession: TabDragSession!
    private(set) var palette: PaletteController!
    private(set) var previews: TabPreviewSource!
    /// CPU and memory for the hover cards and `resources` (sampled on demand).
    private(set) var resources: AppResourceSource!
    let presentation = ContentPresentationScheduler()
    /// Blank-pane invariant, checked after each presentation settle.
    let surfaceInvariant = SurfaceInvariantMonitor()
    /// Input invariants and desync reports (plans/cmux-next/input-spec.md).
    var inputMonitor: InputInvariantMonitor!
    var inputGeometryObservers: [any NSObjectProtocol] = []
    /// No-activate mode only: gives back a keyboard the user did not give.
    var keyboardGuard: NoActivateKeyboardGuard?
    var keyboardGuardObservers: [any NSObjectProtocol] = []
    private(set) var emptyWorkspaces: EmptyWorkspaceRepair!
    /// Reopen Closed Tab history; set when the tab handlers bind.
    var closedTabs: ClosedTabTracker?
    /// The app-wide "where was I" trail (plans/cmux-next/history.md 4.2).
    private(set) lazy var locationTrail = LocationTrailService(services: self)
    /// The merged history read side and the per-profile visit logs.
    private(set) lazy var history = HistoryService(services: self)
    /// `cmux://history`: opens the page and serves its data.
    private(set) lazy var historyPage = HistoryPageService(services: self)
    /// `cmux://agent-activity`: the computer use sessions page.
    private(set) lazy var agentActivityPage = AgentActivityPageService(services: self)
    private(set) lazy var remoteViewPages = RemoteViewPageService()
    /// Recently closed workspaces (history lists).
    private(set) lazy var closedWorkspaces = ClosedWorkspaceTracker(services: self)
    /// Bookmarks of every browser profile (plans/cmux-next/bookmarks.md).
    private(set) lazy var bookmarks = BookmarkService(services: self)
    /// App platform (DEV prototype): registry, JavaScriptCore app host, App Store.
    private(set) lazy var apps = AppsService(services: self)
    /// The Tasks page and its mirror of the local Tasks owner (plans/cmux-next/tasks.md).
    private(set) lazy var tasks = TasksPageService(services: self)
    /// The cmux server menu bar item (DEV and NIGHTLY prototype; plans/cmux-next/server.md 14).
    private(set) lazy var serverMenuBar = ServerMenuBarController()
    /// Home: local conversations with the mux (plans/cmux-next/home.md).
    private(set) lazy var home = HomeService(services: self)
    /// `cmux://bookmarks`: the manager pages.
    private(set) lazy var bookmarkPages = BookmarkPageService(services: self)
    /// The sidebar section layout every window draws (plans/cmux-next/sidebar-sections.md).
    private(set) lazy var sidebarLayout: SidebarLayoutService = {
        let service = SidebarLayoutService(remote: DaemonSidebarLayoutRemote(services: self),
                                           onRefused: { [weak self] message in self?.registry.refuse(message) })
        service.start()
        return service
    }()
    /// Recently closed screens (Reopen Closed Screen).
    let closedScreens = ClosedScreenHistory()
    /// The kinds of tabs opened on purpose, by folder, for `tabs.newTabKind: auto`.
    var newTabKinds = NewTabKindMemory()
    /// Trailing tab-strip buttons from `ui.surfaceTabBar.buttons`.
    private(set) var tabBarButtons: TabBarButtonsController!
    /// System-wide hot keys for catalog actions marked `isGlobalHotKey`.
    private(set) lazy var globalHotKeys = GlobalHotKeyService(registry: registry)
    let terminalDelegate = TerminalHostDelegate()
    /// Attention rings, banners, sounds and dismissal (plans/cmux-next/notifications.md).
    let notifications = NotificationCenterService()
    /// The one keyboard router (plans/cmux-next/focus.md section 5).
    private(set) var keyRouter: KeyRouter!
    private(set) var chromiumWarmup: ChromiumWarmup!
    /// The Settings window (Settings…, Cmd-,).
    private(set) lazy var settingsWindow = SettingsWindowService(services: self)
    /// Debug Settings: tunable overrides and their window (DEV and NIGHTLY).
    private(set) lazy var debugSettings = DebugSettingsService(services: self)
    /// Quit: origin, the keep-or-end sheet and the end of the local sessions.
    private(set) lazy var quit = QuitCoordinator(services: self)
    /// First-run onboarding, browser import and default-app claims.
    private(set) lazy var onboarding = OnboardingService(services: self)
    /// Provider sign-ins and CodeRouter accounts (Settings > Accounts, onboarding).
    private(set) lazy var accounts = AccountsService(services: self)
    /// Links, files and services macOS hands cmux (default browser, ssh:, scripts).
    private(set) lazy var externalOpen = ExternalOpenController(services: self)
    let terminalTheme = TerminalThemeSetting()
    /// Room, workspace and terminal themes.
    private(set) var themes: ThemeCoordinator!
    /// Browser tabs of remote machines reach that machine's localhost.
    private(set) var remoteLocalhost: RemoteLocalhostService!
    var chromiumLikelyObservations: [Task<Void, Never>] = []
    /// Repaints on `appearance.borders` changes (`observeBorders`).
    var borderObservation: Task<Void, Never>?
    /// Page menus and the open-menu diagnostic shared by browser hosts.
    let contextMenus: BrowserContextMenuBuilder
    /// Sized browser popups (OAuth, payment) in floating panels.
    let popups: BrowserPopupPanels
    /// The link-hint session (`f`, `F`) on a focused Chromium page.
    let linkHints = LinkHintController()
    /// Browser profiles: records, the new-tab cascade, each tab's store.
    private(set) lazy var browserProfiles = BrowserProfileService(services: self)
    /// Agent chat tabs and their shared acpmux host (New Agent Chat).
    private(set) lazy var agentTabs = AgentTabStore(tag: environment.tag, registry: registry, linkScheme: linkScheme, git: agentGit, settings: settings)
    /// Quick Agent Chat's floating composer (`palette.quickAgentChat`).
    private(set) lazy var quickComposer = makeQuickComposer()
    /// Internal page tabs (Settings, Debug Settings, the App Store).
    let pages = InternalPageTabStore()
    /// Where imported bookmarks go (the bookmarks feature sets it); nil keeps
    /// them in the import store only.
    var importedBookmarkSink: (any ImportedBookmarkSink)?
    /// Browser tab favicons per profile, for tab strips.
    let favicons = TabFaviconStore()
    /// The one owner of hover cards in the app: at most one card, ever
    /// (plans/cmux-next/hovercards.md).
    let hoverCards = HoverCardCoordinator()
    /// Refusal messages for keyboard and menu runs.
    let refusalHUD = RefusalHUD()
    /// Remote-terminal tabs: mount, placeholder, snapshot, moves.
    private(set) var remoteTerminals: RemoteTerminalService!

    /// - Parameter launchReveal: The launch load-in the windows' sidebars
    ///   hold for; the app-wide one by default.
    init(environment: AppEnvironment, launchReveal: LaunchReveal = .shared) {
        self.launchReveal = launchReveal
        sidebarSnapshots = SidebarSnapshotStore(file: environment.sidebarSnapshotFile)
        let contextMenus = BrowserContextMenuBuilder.shared
        self.contextMenus = contextMenus
        popups = BrowserPopupPanels(contextMenus: contextMenus)
        self.environment = environment
        crashRecovery = CrashRecoveryService(bundleID: environment.launch.bundleID, marksRun: environment.marksRun)
        machines = MachineRegistry(local: daemon)
        machines.isFeatureDisabled = { [registry] in registry.disabledFeatures.contains($0) }
        cloud = CloudService(machines: machines, isDebugBuild: ControlService.isDebugBuild)
        feed = FeedService(auth: cloud.auth)
        ssh = SSHService(machines: machines, bundleID: environment.launch.bundleID)
        BrowserLifecycleTrace.shared.configure { tab, event in
            InputJournal.shared.append(window: nil, .content(tab: tab, event: event))
        }
        cache = TabContentCache(daemon: daemon, cef: CEFEngine(lifecycleTrace: .shared, contextMenus: contextMenus))
        themes = ThemeCoordinator(services: self, terminalThemes: .forApplication(bundleIdentifier: environment.launch.bundleID))
        remoteLocalhost = RemoteLocalhostService(machines: machines)
        cache.configureBrowser = { [weak self] tab, url, base in
            await self?.remoteLocalhost.configuration(for: tab, url: url, base: base) ?? base
        }
        cache.findTab = { [weak self] key in self?.remoteLocalhost.tab(id: key) }
        cache.onRelease = { [weak self] key in self?.home.releaseTabView(key) }
        cache.machineBadge = { [weak self] key, url in
            guard let self, let tab = remoteLocalhost.tab(id: key) else { return nil }
            let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
            return remoteLocalhost.badge(for: tab, url: url, engine: engine)
        }
        cache.defersRestoredPages = crashRecovery.recovery.skipsBrowserPages
        crashRecovery.observe(cache.cef.crashLog)
        cache.cef.onReady = { [crashRecovery] in
            crashRecovery.marker?.installHandlers()
            // Chromium resets signal actions at start and catches SIGINT and
            // SIGHUP itself; they stay requested quits.
            QuitSignal.reclaim()
        }
        cache.cef.openURLWithoutWindow = { [weak self] url, disposition, profile in
            // Chromium wanted a window and has none for that profile (a
            // normal one; an incognito store never gets here): a new browser
            // tab in the focused pane of a normal window (Chromium opens nothing),
            // in the requesting page's browser profile.
            self?.normalWindowForPageRequest()?.focusedPane?.newBrowserTab(url: url, background: disposition == .backgroundTab,
                                                                          profile: profile.map(BrowserProfileRecord.wireID(for:)))
        }
        cache.cef.openOffTheRecord = { [weak self] url, source in self?.openOffTheRecord(url, source: source) }
        cache.browserTabs.isIncognitoTab = { [weak self] key in
            guard let self, let windows, let workspace = workspaceID(ofTab: key) else { return false }
            return windows.isIncognito(workspace: workspace)
        }
        cache.browserTabs.isIncognitoPane = { [weak self] pane in
            guard let self, let windows, let workspace = daemon.store.workspace(containing: pane)?.id else { return false }
            return windows.isIncognito(workspace: workspace)
        }
        cache.browserProfile = { [weak self] key in self?.browserProfiles.engineProfile(forTab: key) }
        cache.profileBadge = { [weak self] key in self?.browserProfiles.omnibarBadge(forTab: key) }
        cache.profileBadgeMenu = { [weak self] key in
            guard let self, let tab = cache.tabModel(key) else { return nil }
            let target = ActionTargetRef(kind: .browserProfile, id: browserProfiles.profileID(ofTab: tab))
            return self.registry.makeContextMenu(for: .browserProfile, target: target)
        }
        cache.browserTabs.resolveProfile = { [weak self] pane, explicit in
            guard let self else { return explicit }
            return browserProfiles.profileForNewTab(in: pane, on: daemon, explicit: explicit)
        }
        emptyWorkspaces = EmptyWorkspaceRepair(daemon: daemon)
        cache.sessionDelegate = terminalDelegate
        cache.pageRequests.services = self
        keyRouter = KeyRouter(registry: registry)
        keyRouter.services = self
        keyRouter.whichKey = WhichKeyController(registry: registry)
        cache.keyRouter = keyRouter
        cache.onPageFocusRequest = { [weak self] key in self?.returnFocusToPage(key) }
        cache.onBrowserEntryCreated = { [registry, unowned self] entry in
            PageInfoHandlers.installRouter(on: entry, registry: registry)
            bookmarks.attach(entry)
        }
        cache.extraSuggestionProviders = { [unowned self] profile in
            [BookmarkSuggestionProvider(service: bookmarks, profile: bookmarks.profile(of: profile))]
        }
        cache.makeExtensionMenuHandler = { [unowned self] key in ExtensionMenuRouter(services: self, tabKey: key) }
        cache.onDevToolsChange = { [weak self] key, state, focused in self?.devToolsDidChange(key, state: state, focused: focused) }
        registry.menuKeyEquivalentGate = { [weak self] id in self?.keyRouter.allowsMenuKeyEquivalent(id) ?? true }
        (NSApp as? CmuxApplication)?.keyDownInterceptor = { [weak self] event, window in
            self?.keyRouter.interceptKeyDown(event, in: window) ?? false
        }
        surfaceInvariant.services = self
        cache.onPresentationChange = { [weak self] in self?.surfaceInvariant.noteChange() }
        resources = AppResourceSource(services: self)
        windows = WindowManager(services: self)
        windows.incognitoHistoryReset = { [weak cache, weak self] in
            cache?.resetIncognitoHistory()
            self?.locationTrail.forgetIncognito()
        }
        dragSession = TabDragSession(services: self)
        previews = TabPreviewSource(cache: cache)
        remoteTerminals = RemoteTerminalService(services: self)
        remoteTerminals.start()
        WorkspaceClose.willClose = { [weak self] workspace in self?.remoteTerminals.workspaceClosing(workspace) }
        let registry = registry
        daemon.workTracker = { registry.track($0) }
        palette = PaletteController(registry: registry, sources: PaletteSourcesBridge.make(services: self))
        terminalDelegate.services = self
        tabBarButtons = TabBarButtonsController(context: AppActionContext(services: self))
        let updateSheet = UpdateSheetController(source: UpdateSheetModel(service: updater))
        self.updateSheet = updateSheet
        updater.presentUpdateUI = { [weak self] in updateSheet.present(in: self?.windows.active?.window) }
        cache.onBrowserReady = { [weak self] key in
            for controller in self?.windows.controllers ?? [] {
                for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pane.currentTabKey == key { pane.showSelected() }
            }
        }
        observePaletteForFocus()
        startInputVerification()
        startNoActivateGuard()
        chromiumWarmup = ChromiumWarmup(engine: cache.cef)
        notifications.start(services: self)
        keyRouter.onTyping = { [weak self] window in self?.notifications.noteTyping(in: window) }
        (NSApp as? CmuxApplication)?.mouseDownObserver = { [weak self] window in
            self?.notifications.noteMouseDown(in: window)
            // A click anywhere ends link hints and a waiting chord (it may move the keyboard).
            self?.linkHints.cancel()
            self?.keyRouter.cancelChord()
        }
    }

    // MARK: Lookup

    /// The tab with durable id `id` and the pane that holds it.
    func locateTab(_ id: String) -> (TabModel, PaneModel)? {
        for (workspace, _) in machines.allWorkspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    // A tab first seen without a `tab_` resource id keeps
                    // its first id; links name it by the resource id.
                    if let tab = pane.tabs.first(where: { $0.id == id || $0.snapshot.tabResourceID?.rawValue == id }) {
                        return (tab, pane)
                    }
                }
            }
        }
        return nil
    }

    /// The tab on `surface` (the local daemon's surfaces).
    func locateTab(surface: SurfaceID) -> TabModel? {
        daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.surface == surface }
    }

    func workspace(id: String) -> WorkspaceModel? {
        machines.workspace(id: id)?.0
    }

    /// The daemon that owns `pane`.
    func daemon(for pane: PaneModel) -> DaemonService {
        machines.daemon(forPane: pane)
    }

    /// The workspace key of `pane`, for `SpawnOptions.workspace`: a new
    /// terminal there gets `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`.
    func workspaceKey(of pane: PaneModel) -> WorkspaceKey? {
        daemon(for: pane).store.workspace(containing: pane.handle)?.key
    }

    /// Durable resource ids of `pane` and its screen and workspace
    /// (`terminal.project` destinations); nil on pre-registry daemons.
    func resourcePath(of pane: PaneModel) -> PaneResourcePath? {
        guard let workspace = daemon(for: pane).store.workspace(containing: pane.handle),
              let screen = workspace.screens.first(where: { $0.panes.contains { $0 === pane } }),
              let workspaceID = workspace.resourceID, let screenID = screen.resourceID, let paneID = pane.resourceID else { return nil }
        return PaneResourcePath(workspace: workspaceID, screen: screenID, pane: paneID)
    }

    /// Ends a detached tab drag whose move failed: the tab reappears.
    func restoreDetachedTab(_ id: String) {
        for controller in windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                pane.view.stripView.restoreDetachedTab(StripTabID(id))
                pane.resyncStrip()
            }
        }
    }

    /// The pane controller showing `pane` in the active window, if any.
    /// The controller showing `pane` itself. Handles are daemon-local
    /// numbers that repeat across machines, so a handle match counts only
    /// when the controller shows this very model.
    func paneController(for pane: PaneModel) -> PaneController? {
        for controller in windows.controllers {
            if let found = controller.content?.pane(for: pane.handle), found.pane === pane { return found }
        }
        return nil
    }
}
