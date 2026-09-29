import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTerminal

/// Process-wide services the window controllers share. Model state is not
/// here: the daemon owns it, windows own their local state.
final class AppServices {
    let environment: AppEnvironment
    let daemon = DaemonService()
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
        for workspace in daemon.store.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let tab = pane.tabs.first(where: { $0.id == id }) { return (tab, pane) }
                }
            }
        }
        return nil
    }

    func workspace(id: String) -> WorkspaceModel? {
        daemon.store.workspaces.first { $0.id == id }
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
