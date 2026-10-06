import AppKit
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
    private(set) var emptyView: EmptyWorkspaceView?
    private(set) var screenBar: ScreenBarController!
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
    private var settlingObservation: Task<Void, Never>?
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
        screenBar = ScreenBarController(content: self)
        contentView = WorkspaceContentView(layoutView: layoutView, bar: screenBar.view)
        let fallbackCreate = emptyWorkspaceRepair.create
        emptyWorkspaceRepair.createFirst = { [weak services, weak daemon] key in
            guard let services, let daemon, let workspace = daemon.store.workspaces.first(where: { $0.key == key }) else { throw DaemonError.notConnected }
            if services.agentTabs.canHost(on: daemon) {
                return try await services.agentTabs.openFirstPage(in: workspace, on: daemon, services: services)
            }
            return try await fallbackCreate(key)
        }
        emptyView = EmptyWorkspaceView(
            onNew: { [weak self] in self?.newFromEmptyState() },
            onImportAndSync: { [weak services] in services?.onboarding.show(step: .projects) }
        )
        themeScope.root(contentView)
        contentView.showsBar = screenBar.isVisible
        screenBar.onVisibilityChange = { [weak self] visible in self?.contentView.showsBar = visible }
        // Observation applies the first snapshot synchronously, including the empty-state view.
        observe()
    }

    func teardown() {
        observation?.cancel()
        connectionObservation?.cancel()
        attentionObservation?.cancel()
        settlingObservation?.cancel()
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
        // A first terminal or a close that starts or ends while the
        // workspace is empty decides whether it offers its actions.
        let repair = emptyWorkspaceRepair
        settlingObservation = Task { [weak self] in
            for await _ in Observations({ workspace.key.map { repair.isSettling($0) } ?? false }) {
                self?.updateEmptyState()
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
        updateEmptyState()
        repairIfEmpty()
        sendTopology()
    }

    /// A workspace with no pane shows actions; an explicit New creates the
    /// first terminal and focuses it when the daemon reports the surface.
    /// One that is settling (its first terminal on the way, or closing)
    /// shows nothing: its actions would flash for a frame before the tab
    /// strip and terminal land, or before it closes.
    private func updateEmptyState() {
        let isEmpty = layoutModel.screens.allSatisfy { $0.layout.panes.isEmpty }
        let settling = workspace.key.map { emptyWorkspaceRepair.isSettling($0) } ?? false
        contentView.showEmpty(isEmpty && !settling ? emptyView : nil)
    }

    private func newFromEmptyState() {
        guard let key = workspace.key else {
            services.windows.newWorkspace(in: state)
            return
        }
        emptyWorkspaceRepair.createFirstTab(key) { [weak self] surface in
            guard let self else { return }
            focus.expect(.surface(String(surface.rawValue)))
            applyCurrent()
        }
    }

    /// A lost terminal gets one replacement, focused when it lands.
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
        services.paneMounts.changed()
        sendTopology()
        // Settings… asked before any window had a pane waits for the first one (R82). It opens
        // its tab after this layout pass, never inside it.
        if panes.count == 1, services.settingsWindow.isWaiting {
            let settings = services.settingsWindow
            Task { settings.windowDidShowContent() }
        }
        return controller.view
    }

    func releaseContentView(_ view: NSView, for pane: LayoutPaneID) {
        panes.removeValue(forKey: pane)?.teardown()
        services.paneMounts.changed()
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
