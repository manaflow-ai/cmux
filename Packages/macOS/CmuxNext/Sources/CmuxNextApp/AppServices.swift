import AppKit
import CmuxNextActions
import CmuxNextBridge
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
    /// The local daemon. Cloud machines are in `machines`; code acting on a
    /// workspace, pane, or tab resolves its daemon through `machines`.
    let daemon = DaemonService()
    let machines: MachineRegistry
    /// The machine of the action being run, while its handler runs
    /// (`ActionRouting`); `activeDaemon` prefers it.
    var routedDaemon: DaemonService?
    private(set) var cloud: CloudService!
    /// Phone access; started by the account layer once signed in.
    let mobile = MobileHostService()
    let registry = ActionRegistry.standard()
    /// Sparkle updates (release builds) or read-only feed probes (DEV).
    let updater = UpdaterService()
    private(set) var updateSheet: UpdateSheetController!
    /// cmux.json controller; set by `AppDelegate` once it starts.
    var settings: SettingsController?
    private(set) var cache: TabContentCache!
    private(set) var windows: WindowManager!
    private(set) var dragSession: TabDragSession!
    private(set) var palette: PaletteController!
    private(set) var previews: TabPreviewSource!
    /// App side of the cmux CLI compat layer (window/focus state, intents).
    private(set) var compat: AppCompatFrontend!
    let presentation = ContentPresentationScheduler()
    /// Blank-pane invariant, checked after each presentation settle.
    let surfaceInvariant = SurfaceInvariantMonitor()
    /// Input invariants and desync reports (plans/cmux-next/input-spec.md).
    var inputMonitor: InputInvariantMonitor!
    /// Hook statuses shown in sidebar rows (`set_status`).
    let statusBoard = WorkspaceStatusBoard()
    private(set) var emptyWorkspaces: EmptyWorkspaceRepair!
    /// Reopen Closed Tab history; set when the tab handlers bind.
    var closedTabs: ClosedTabTracker?
    /// Trailing tab-strip buttons from `ui.surfaceTabBar.buttons`.
    private(set) var tabBarButtons: TabBarButtonsController!
    let terminalDelegate = TerminalHostDelegate()
    /// The one keyboard router (plans/cmux-next/focus.md section 5).
    private(set) var keyRouter: KeyRouter!
    var paletteObservation: Task<Void, Never>?
    private(set) var chromiumWarmup: ChromiumWarmup!
    var chromiumLikelyObservations: [Task<Void, Never>] = []

    init(environment: AppEnvironment) {
        self.environment = environment
        machines = MachineRegistry(local: daemon)
        cloud = CloudService(machines: machines, isDebugBuild: ControlService.isDebugBuild)
        cache = TabContentCache(daemon: daemon)
        emptyWorkspaces = EmptyWorkspaceRepair(daemon: daemon)
        cache.sessionDelegate = terminalDelegate
        cache.pageRequests.services = self
        keyRouter = KeyRouter(registry: registry)
        keyRouter.services = self
        cache.keyRouter = keyRouter
        cache.onPageFocusRequest = { [weak self] key in self?.returnFocusToPage(key) }
        cache.onBrowserEntryCreated = { [registry] entry in PageInfoHandlers.installRouter(on: entry, registry: registry) }
        cache.makeExtensionMenuHandler = { [unowned self] key in ExtensionMenuRouter(services: self, tabKey: key) }
        registry.menuKeyEquivalentGate = { [weak self] id in self?.keyRouter.allowsMenuKeyEquivalent(id) ?? true }
        (NSApp as? CmuxApplication)?.keyDownInterceptor = { [weak self] event, window in
            self?.keyRouter.interceptKeyDown(event, in: window) ?? false
        }
        surfaceInvariant.services = self
        cache.onPresentationChange = { [weak self] in self?.surfaceInvariant.noteChange() }
        windows = WindowManager(services: self)
        dragSession = TabDragSession(services: self)
        previews = TabPreviewSource(cache: cache)
        compat = AppCompatFrontend(services: self)
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
        chromiumWarmup = ChromiumWarmup(engine: cache.cef)
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
    func paneController(for pane: PaneModel) -> PaneController? {
        for controller in windows.controllers {
            if let found = controller.content?.pane(for: pane.handle) { return found }
        }
        return nil
    }
}
