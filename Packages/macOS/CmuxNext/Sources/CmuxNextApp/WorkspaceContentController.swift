import AppKit
import CmuxNextAgentCursor
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
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
    /// Layout plus the bottom screen bar; what the window shows.
    private(set) var contentView: WorkspaceContentView!
    private(set) var screenBar: ScreenBarController!
    /// Agent cursors drawn in this content's overlay plane
    /// (plans/cmux-next/agent-cursor.md). Drivers publish through
    /// `agentCursor.publisher`; placement comes from the visibility source.
    /// With no input events it draws nothing.
    private(set) var agentCursor: AgentCursorStack?
    /// The workspace theme: only this content area, under the window's
    /// room theme.
    let themeScope = ThemeScope(level: .workspace)
    unowned let services: AppServices
    unowned let state: WindowState
    private(set) var handles = LayoutHandleMap()
    private(set) var panes: [LayoutPaneID: PaneController] = [:]
    private var observation: Task<Void, Never>?
    private var connectionObservation: Task<Void, Never>?
    private var attentionObservation: Task<Void, Never>?
    /// Daemon `transaction` for each layout gesture (undo coalescing).
    var gestureTransactions: [LayoutTransactionID: UInt64] = [:]
    /// The window's focus state machine (`WindowState.focus`,
    /// plans/cmux-next/focus.md). Every focus change in this content goes
    /// through it.
    let focus: FocusCoordinator
    var nextGestureTransaction: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) << 8
    /// Kept mounted off screen by its window (a recently shown workspace):
    /// its panes are paused in the keep-alive band and it sends no focus
    /// events, because the window's focus follows the shown workspace.
    private(set) var isParked = false

    /// Parks this content before its window shows another workspace.
    func park() {
        isParked = true
        layoutView.keepsPanesWhenDetached = true
    }

    /// Shows this parked content again (the window installs its view next).
    func unpark() {
        isParked = false
        layoutView.keepsPanesWhenDetached = false
        applyCurrent()
    }

    init(workspace: WorkspaceModel, daemon: DaemonService, services: AppServices, state: WindowState) {
        self.workspace = workspace
        self.daemon = daemon
        self.services = services
        self.state = state
        focus = state.focus
        layoutModel.intentHandler = { [weak self] intent in self?.handle(intent) }
        layoutView = LayoutRootView(model: layoutModel, contentProvider: self)
        if let planeLayer = layoutView.overlayPlane.layer {
            agentCursor = AgentCursorStack(hostLayer: planeLayer, resolver: services.agentCursorVisibility.resolver(for: self))
        }
        observe()
        screenBar = ScreenBarController(content: self)
        contentView = WorkspaceContentView(layoutView: layoutView, bar: screenBar.view)
        themeScope.root(contentView)
        contentView.showsBar = screenBar.isVisible
        screenBar.onVisibilityChange = { [weak self] visible in self?.contentView.showsBar = visible }
    }

    func teardown() {
        observation?.cancel()
        connectionObservation?.cancel()
        attentionObservation?.cancel()
        screenBar.teardown()
        for controller in panes.values { controller.teardown() }
        panes.removeAll()
        contentView.removeFromSuperview()
    }

    private func observe() {
        let workspace = workspace
        apply(LayoutMapping.shared.map(workspace))
        observation = Task { [weak self] in
            for await result in Observations({ LayoutMapping.shared.map(workspace) }) {
                self?.apply(result)
            }
        }
        // An empty workspace loaded while disconnected, or drawn from the
        // launch snapshot, is repaired once the daemon is back and its tree
        // is live, even if the tree itself does not change.
        let store = daemon.store
        connectionObservation = Task { [weak self] in
            for await _ in Observations({ (String(describing: store.connectionState), store.isLoaded) }) {
                self?.repairIfEmpty()
            }
        }
        // Panes with an unread notification draw the attention ring.
        let notifications = services.notifications
        attentionObservation = Task { [weak self] in
            for await marks in Observations({ notifications.attentionMarks(for: workspace) }) {
                guard let self else { return }
                if self.layoutModel.attention != marks { self.layoutModel.attention = marks }
            }
        }
    }

    /// Re-applies the current store state (after a command response that
    /// may trail its own delta).
    func applyCurrent() {
        apply(LayoutMapping.shared.map(workspace))
    }

    private func apply(_ result: LayoutMapping.Result) {
        handles = result.handles
        layoutModel.acceptsEdgeDockDrops = daemon.supports(DaemonCapabilities.shared.edgeDocks)
        // No row op is sent to a daemon without rows-v1 (rows.md step 4).
        let rows = daemon.supports(DaemonCapabilities.shared.rows)
        if layoutModel.acceptsRowOps != rows { layoutModel.acceptsRowOps = rows }
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
        services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)
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

    func panePresenceDidChange(_ pane: LayoutPaneID, presence: PanePresence) {
        let surfacePresence: SurfacePresence = switch presence {
        case .visible: .visible
        case .keepAlive: .keepAlive
        case .hidden: .hidden
        }
        panes[pane]?.setPresence(surfacePresence)
    }
}
