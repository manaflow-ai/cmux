import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextUpdater

/// Process-wide services the window controllers share. Model state is not
/// here: the daemon owns it, windows own their local state.
final class AppServices {
    let environment: AppEnvironment
    /// Run marker, restart notice, crash reports (`debug.crashes`).
    let crashRecovery: CrashRecoveryService
    /// The local daemon. Cloud machines are in `machines`; code acting on a
    /// workspace, pane, or tab resolves its daemon through `machines`.
    let daemon = DaemonService()
    let machines: MachineRegistry
    /// The machine of the action being run, while its handler runs
    /// (`ActionRouting`); `activeDaemon` prefers it.
    var routedDaemon: DaemonService?
    private(set) var cloud: CloudService!
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
    private(set) var emptyWorkspaces: EmptyWorkspaceRepair!
    /// Reopen Closed Tab history; set when the tab handlers bind.
    var closedTabs: ClosedTabTracker?
    /// Recently closed screens (Reopen Closed Screen).
    let closedScreens = ClosedScreenHistory()
    /// Trailing tab-strip buttons from `ui.surfaceTabBar.buttons`.
    private(set) var tabBarButtons: TabBarButtonsController!
    let terminalDelegate = TerminalHostDelegate()
    /// Attention rings, banners, sounds and dismissal (plans/cmux-next/notifications.md).
    let notifications = NotificationCenterService()
    /// The one keyboard router (plans/cmux-next/focus.md section 5).
    private(set) var keyRouter: KeyRouter!
    private(set) var chromiumWarmup: ChromiumWarmup!
    /// The Settings window (Settings…, Cmd-,).
    private(set) lazy var settingsWindow = SettingsWindowService(services: self)
    /// First-run onboarding, browser import and default-app claims.
    private(set) lazy var onboarding = OnboardingService(services: self)
    /// Links, files and services macOS hands cmux (default browser, ssh:, scripts).
    private(set) lazy var externalOpen = ExternalOpenController(services: self)
    let terminalTheme = TerminalThemeSetting()
    /// Browser tabs of remote machines reach that machine's localhost.
    private(set) var remoteLocalhost: RemoteLocalhostService!
    var chromiumLikelyObservations: [Task<Void, Never>] = []
    /// Sized browser popups (OAuth, payment) in floating panels.
    let popups = BrowserPopupPanels()

    init(environment: AppEnvironment) {
        self.environment = environment
        crashRecovery = CrashRecoveryService(bundleID: environment.launch.bundleID, marksRun: environment.marksRun)
        machines = MachineRegistry(local: daemon)
        cloud = CloudService(machines: machines, isDebugBuild: ControlService.isDebugBuild)
        ssh = SSHService(machines: machines, bundleID: environment.launch.bundleID)
        cache = TabContentCache(daemon: daemon)
        remoteLocalhost = RemoteLocalhostService(machines: machines)
        cache.configureBrowser = { [weak self] tab, url, base in
            await self?.remoteLocalhost.configuration(for: tab, url: url, base: base) ?? base
        }
        cache.findTab = { [weak self] key in self?.remoteLocalhost.tab(id: key) }
        cache.machineBadge = { [weak self] key, url in
            guard let self, let tab = remoteLocalhost.tab(id: key) else { return nil }
            let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
            return remoteLocalhost.badge(for: tab, url: url, engine: engine)
        }
        cache.defersRestoredPages = crashRecovery.recovery.skipsBrowserPages
        crashRecovery.observe(cache.cef.crashLog)
        cache.cef.onReady = { [crashRecovery] in crashRecovery.marker?.installHandlers() }
        cache.cef.openURLWithoutWindow = { [weak self] url, disposition in
            // Chromium wanted a window and has none for that profile (a
            // normal one; an incognito store never gets here): a new browser
            // tab in the focused pane of a normal window (Chromium opens nothing).
            self?.normalWindowForPageRequest()?.focusedPane?.newBrowserTab(url: url, background: disposition == .backgroundTab)
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
        cache.browserProfile = { [weak self] key in
            guard let self, let windows else { return nil }
            return windows.browserProfile(forWorkspace: workspaceID(ofTab: key))
        }
        emptyWorkspaces = EmptyWorkspaceRepair(daemon: daemon)
        cache.sessionDelegate = terminalDelegate
        cache.pageRequests.services = self
        keyRouter = KeyRouter(registry: registry)
        keyRouter.services = self
        cache.keyRouter = keyRouter
        cache.onPageFocusRequest = { [weak self] key in self?.returnFocusToPage(key) }
        cache.onBrowserEntryCreated = { [registry] entry in PageInfoHandlers.installRouter(on: entry, registry: registry) }
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
        windows.incognitoHistoryReset = { [weak cache] in cache?.resetIncognitoHistory() }
        dragSession = TabDragSession(services: self)
        previews = TabPreviewSource(cache: cache)
        let registry = registry
        daemon.workTracker = { registry.track($0) }
        palette = PaletteController(registry: registry, sources: PaletteSourcesBridge.make(services: self))
        terminalDelegate.services = self
        tabBarButtons = TabBarButtonsController(context: AppActionContext(services: self))
        let updateSheet = UpdateSheetController(source: UpdateSheetModel(service: updater))
        self.updateSheet = updateSheet
        updater.presentUpdateUI = { [weak self] in updateSheet.present(in: self?.windows.active?.window) }
        BrowserLifecycleTrace.sink = { tab, event in InputJournal.shared.append(window: nil, .content(tab: tab, event: event)) }
        cache.onBrowserReady = { [weak self] key in
            for controller in self?.windows.controllers ?? [] {
                for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pane.currentTabKey == key { pane.showSelected() }
            }
        }
        observePaletteForFocus()
        startInputVerification()
        chromiumWarmup = ChromiumWarmup(engine: cache.cef)
        notifications.start(services: self)
        keyRouter.onTyping = { [weak self] window in self?.notifications.noteTyping(in: window) }
        (NSApp as? CmuxApplication)?.mouseDownObserver = { [weak self] window in self?.notifications.noteMouseDown(in: window) }
    }

    // MARK: Lookup

    /// The tab with durable id `id` and the pane that holds it.
    func locateTab(_ id: String) -> (TabModel, PaneModel)? {
        for (workspace, _) in machines.allWorkspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let tab = pane.tabs.first(where: { $0.id == id }) { return (tab, pane) }
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
