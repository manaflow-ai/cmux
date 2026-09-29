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
    var nextGestureTransaction: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) << 8

    init(workspace: WorkspaceModel, services: AppServices, state: WindowState) {
        self.workspace = workspace
        self.services = services
        self.state = state
        layoutModel.intentHandler = { [weak self] intent in self?.handle(intent) }
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
        let store = services.daemon.store
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
        services.emptyWorkspaces.check(workspace) { [weak self] surface in
            guard let self else { return }
            self.pendingFocusSurface = surface
            self.applyCurrent()
        }
    }

    // MARK: Focus

    var focusedPane: PaneController? {
        layoutModel.focusedPane.flatMap { panes[$0] } ?? panes.values.first
    }

    /// First responder moved into `pane`.
    func paneDidFocus(_ pane: PaneController) {
        state.focusedPane[workspace.id] = pane.layoutPaneID
        var context = services.registry.context
        context.subtract([.terminalFocused, .browserFocused])
        switch pane.currentContent {
        case .terminal: context.insert(.terminalFocused)
        case .browser: context.insert(.browserFocused)
        case nil: break
        }
        if services.registry.context != context { services.registry.context = context }
        layoutModel.focus(pane.layoutPaneID)
    }

    func focusCurrentPane() {
        focusedPane?.focusContent()
    }

    func pane(for handle: DaemonPaneID) -> PaneController? {
        handles.paneIDs[handle].flatMap { panes[$0] }
    }

    // MARK: LayoutPaneContentProvider

    func makeContentView(for pane: LayoutPaneID) -> NSView {
        guard let handle = handles.panes[pane], let model = services.daemon.store.pane(handle) else { return NSView() }
        let controller = PaneController(pane: model, layoutPaneID: pane, services: services, state: state)
        controller.workspace = self
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
