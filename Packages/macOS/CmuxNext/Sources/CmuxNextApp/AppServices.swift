import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTerminal

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
    /// Hook statuses shown in sidebar rows (`set_status`).
    let statusBoard = WorkspaceStatusBoard()
    private(set) var emptyWorkspaces: EmptyWorkspaceRepair!
    /// Trailing tab-strip buttons from `ui.surfaceTabBar.buttons`.
    private(set) var tabBarButtons: TabBarButtonsController!
    private let terminalDelegate = TerminalHostDelegate()

    init(environment: AppEnvironment) {
        self.environment = environment
        machines = MachineRegistry(local: daemon)
        cloud = CloudService(machines: machines, isDebugBuild: ControlService.isDebugBuild)
        cache = TabContentCache(daemon: daemon)
        emptyWorkspaces = EmptyWorkspaceRepair(daemon: daemon)
        cache.sessionDelegate = terminalDelegate
        windows = WindowManager(services: self)
        dragSession = TabDragSession(services: self)
        previews = TabPreviewSource(cache: cache)
        compat = AppCompatFrontend(services: self)
        let registry = registry
        daemon.workTracker = { registry.track($0) }
        palette = PaletteController(registry: registry, sources: PaletteSourcesBridge.make(services: self))
        terminalDelegate.services = self
        tabBarButtons = TabBarButtonsController(context: AppActionContext(services: self))
        cache.onBrowserReady = { [weak self] key in
            for controller in self?.windows.controllers ?? [] {
                for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pane.currentTabKey == key { pane.showSelected() }
            }
        }
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
