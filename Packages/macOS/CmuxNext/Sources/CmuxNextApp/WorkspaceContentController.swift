import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import Observation

/// The content area of one window for one workspace: a `LayoutRootView`
/// whose leaves are `PaneController`s. Mirrors the daemon split tree and
/// columns into the layout model and turns layout intents into commands.
final class WorkspaceContentController: LayoutPaneContentProvider {
    let workspace: WorkspaceModel
    /// The machine daemon that owns `workspace`; every command goes there.
    let daemon: DaemonService
    let layoutModel = LayoutModel()
    private(set) var layoutView: LayoutRootView!
    unowned let services: AppServices
    unowned let state: WindowState
    private(set) var handles = LayoutHandleMap()
    private(set) var panes: [LayoutPaneID: PaneController] = [:]
    private var observation: Task<Void, Never>?
    private var connectionObservation: Task<Void, Never>?
    /// Daemon `transaction` for each layout gesture (undo coalescing).
    var gestureTransactions: [LayoutTransactionID: UInt64] = [:]
    /// The first tab of a pane this window just created (split, column);
    /// its pane takes focus once the daemon reports it.
    var pendingFocusSurface: SurfaceID?
    /// A blank browser tab created into a new pane; that pane focuses its
    /// address bar once it exists.
    var pendingAddressBarFocus: SurfaceID?
    var nextGestureTransaction: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) << 8

    init(workspace: WorkspaceModel, daemon: DaemonService, services: AppServices, state: WindowState) {
        self.workspace = workspace
        self.daemon = daemon
        self.services = services
        self.state = state
        layoutModel.intentHandler = { [weak self] intent in self?.handle(intent) }
        layoutModel.showsScreenSwitcher = state.showsScreenSwitcher
        layoutView = LayoutRootView(model: layoutModel, contentProvider: self)
        observe()
    }

    func teardown() {
        observation?.cancel()
        connectionObservation?.cancel()
        for controller in panes.values { controller.teardown() }
        panes.removeAll()
        layoutView.removeFromSuperview()
    }

    private func observe() {
        let workspace = workspace
        apply(LayoutMapping.map(workspace))
        observation = Task { [weak self] in
            for await result in Observations({ LayoutMapping.map(workspace) }) {
                self?.apply(result)
            }
        }
        // An empty workspace loaded while disconnected is repaired once the
        // daemon is back, even if the tree itself does not change.
        let store = daemon.store
        connectionObservation = Task { [weak self] in
            for await _ in Observations({ store.connectionState }) { self?.repairIfEmpty() }
        }
    }

    /// Re-applies the current store state (after a command response that
    /// may trail its own delta).
    func applyCurrent() {
        apply(LayoutMapping.map(workspace))
    }

    private func apply(_ result: LayoutMapping.Result) {
        handles = result.handles
        layoutModel.apply(screens: result.screens)
        repairIfEmpty()
        if let surface = pendingFocusSurface,
           let pane = workspace.screens.flatMap(\.panes).first(where: { $0.tabs.contains { $0.surface == surface } }) {
            pendingFocusSurface = nil
            state.focusedPane[workspace.id] = LayoutPaneID(pane.id)
            layoutModel.focus(LayoutPaneID(pane.id))
            return
        }
        if let remembered = state.focusedPane[workspace.id], layoutModel.focusedPane != remembered,
           result.screens.contains(where: { $0.layout.contains(remembered) }) {
            layoutModel.focus(remembered)
        }
    }

    /// A workspace with no pane gets one terminal, focused when it lands.
    private func repairIfEmpty() {
        emptyWorkspaceRepair.check(workspace) { [weak self] surface in
            guard let self else { return }
            self.pendingFocusSurface = surface
            self.applyCurrent()
        }
    }

    /// The local daemon's repair, or the owning Cloud machine's.
    private var emptyWorkspaceRepair: EmptyWorkspaceRepair {
        services.machines.session(daemon.machineID)?.emptyWorkspaces ?? services.emptyWorkspaces
    }

    // MARK: Focus

    var focusedPane: PaneController? {
        layoutModel.focusedPane.flatMap { panes[$0] } ?? panes.values.first
    }

    /// First responder moved into `pane`.
    func paneDidFocus(_ pane: PaneController) {
        state.focusedPane[workspace.id] = pane.layoutPaneID
        layoutModel.focus(pane.layoutPaneID)
        publishContext()
    }

    /// Publishes the focused pane's content kind (`terminalFocused`,
    /// `browserFocused`) to the action registry. Runs on every change that
    /// can alter it (pane focus, tab selection, content becoming ready), not
    /// only on first-responder moves, so CLI and palette runs see a browser
    /// tab created or selected without a click. Only the active window's
    /// content publishes.
    func publishContext() {
        if let active = services.windows.active, active.content !== self { return }
        let registry = services.registry
        let context = ContentContext.merged(registry.context, content: focusedPane?.currentContent)
        if registry.context != context { registry.context = context }
    }

    func focusCurrentPane() {
        focusedPane?.focusContent()
    }

    func pane(for handle: DaemonPaneID) -> PaneController? {
        handles.paneIDs[handle].flatMap { panes[$0] }
    }

    // MARK: LayoutPaneContentProvider

    func makeContentView(for pane: LayoutPaneID) -> NSView {
        guard let handle = handles.panes[pane], let model = daemon.store.pane(handle) else { return NSView() }
        let controller = PaneController(pane: model, daemon: daemon, layoutPaneID: pane, services: services, state: state)
        controller.workspace = self
        if let surface = pendingAddressBarFocus, model.tabs.contains(where: { $0.surface == surface }) {
            pendingAddressBarFocus = nil
            controller.pendingAddressBarFocus = surface
        }
        panes[pane] = controller
        if layoutModel.focusedPane == pane, controller.view.window != nil { controller.focusContent() }
        return controller.view
    }

    func releaseContentView(_ view: NSView, for pane: LayoutPaneID) {
        panes.removeValue(forKey: pane)?.teardown()
    }

    func paneVisibilityDidChange(_ pane: LayoutPaneID, isVisible: Bool) {
        panes[pane]?.setVisible(isVisible)
    }
}
