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
    private(set) var cloud: CloudService!
    let registry = ActionRegistry.standard()
    /// cmux.json controller; set by `AppDelegate` once it starts.
    var settings: SettingsController?
    private(set) var cache: TabContentCache!
    private(set) var windows: WindowManager!
    private(set) var dragSession: TabDragSession!
    private(set) var palette: PaletteController!
    private(set) var previews: TabPreviewSource!
    private(set) var emptyWorkspaces: EmptyWorkspaceRepair!
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
        palette = PaletteController(registry: registry, sources: PaletteSourcesBridge.make(services: self))
        terminalDelegate.services = self
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

/// Handles terminal requests that need the app (links, close requests).
final class TerminalHostDelegate: TerminalSessionDelegate {
    weak var services: AppServices?

    func terminalSession(_ session: TerminalSession, open url: URL) -> Bool {
        guard let pane = services?.windows.active?.focusedPane, url.scheme == "http" || url.scheme == "https" else {
            return NSWorkspace.shared.open(url)
        }
        pane.newBrowserTab(url: url)
        return true
    }

    func terminalSession(_ session: TerminalSession, didPostNotification title: String, body: String) {
        let text = body
        services?.daemon.send("notify") { connection in _ = try await connection.notify(title: title, body: text) }
    }
}
