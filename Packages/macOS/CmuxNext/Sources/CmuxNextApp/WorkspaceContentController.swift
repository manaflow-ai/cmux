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
    /// The window's focus state machine (`WindowState.focus`,
    /// plans/cmux-next/focus.md). Every focus change in this content goes
    /// through it.
    let focus: FocusCoordinator
    var nextGestureTransaction: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) << 8

    init(workspace: WorkspaceModel, daemon: DaemonService, services: AppServices, state: WindowState) {
        self.workspace = workspace
        self.daemon = daemon
        self.services = services
        self.state = state
        focus = state.focus
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
        sendTopology()
    }

    /// A workspace with no pane gets one terminal, focused when it lands.
    private func repairIfEmpty() {
        emptyWorkspaceRepair.check(workspace) { [weak self] surface in
            guard let self else { return }
            self.focus.expect(.surface(String(surface.rawValue)))
            self.applyCurrent()
        }
    }

    /// The local daemon's repair, or the owning Cloud machine's.
    private var emptyWorkspaceRepair: EmptyWorkspaceRepair {
        services.machines.session(daemon.machineID)?.emptyWorkspaces ?? services.emptyWorkspaces
    }

    // MARK: Focus

    /// The coordinator's focused pane, else the first pane in layout order
    /// (deterministic; never dictionary order).
    var focusedPane: PaneController? {
        if let id = focus.state.pane, let controller = panes[LayoutPaneID(id)] { return controller }
        for id in layoutModel.screens.flatMap(\.layout.panes) {
            if let controller = panes[id] { return controller }
        }
        return nil
    }

    /// The controller of the pane with daemon id `key`.
    func paneController(key: String) -> PaneController? { panes[LayoutPaneID(key)] }

    func pane(for handle: DaemonPaneID) -> PaneController? {
        handles.paneIDs[handle].flatMap { panes[$0] }
    }

    // MARK: LayoutPaneContentProvider

    func makeContentView(for pane: LayoutPaneID) -> NSView {
        guard let handle = handles.panes[pane], let model = daemon.store.pane(handle) else { return NSView() }
        let controller = PaneController(pane: model, daemon: daemon, layoutPaneID: pane, services: services, state: state)
        controller.workspace = self
        panes[pane] = controller
        sendTopology()
        return controller.view
    }

    func releaseContentView(_ view: NSView, for pane: LayoutPaneID) {
        panes.removeValue(forKey: pane)?.teardown()
    }

    func paneVisibilityDidChange(_ pane: LayoutPaneID, isVisible: Bool) {
        panes[pane]?.setVisible(isVisible)
    }
}
