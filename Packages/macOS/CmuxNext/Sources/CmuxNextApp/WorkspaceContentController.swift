import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
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
    // Built in init in this order (lazy because they hold self; no IUOs).
    private(set) lazy var layoutView = LayoutRootView(model: layoutModel, contentProvider: self)
    /// Layout plus the bottom screen bar; what the window shows.
    private(set) lazy var contentView = WorkspaceContentView(layoutView: layoutView, bar: screenBar.view)
    private(set) var emptyView: EmptyWorkspaceView?
    private(set) lazy var screenBar = ScreenBarController(content: self)
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
    /// True while `apply` mounts panes: it sends the topology once at its end,
    /// so a mount inside it does not rebuild the O(N) topology per pane (O(N^2)).
    private var isApplying = false
    private var appliedTree = LayoutAppliedTree()
    /// Daemon `transaction` for each layout gesture (undo coalescing).
    var gestureTransactions: [LayoutTransactionID: UInt64] = [:]
    /// The window's focus state machine (`WindowState.focus`,
    /// plans/cmux-next/focus.md). Every focus change in this content goes
    /// through it.
    let focus: FocusCoordinator
    var nextGestureTransaction: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) << 8
    /// Kept mounted off screen by its window (a workspace it showed): its panes report hidden, so
    /// their surfaces pause and only the warm set's LRU may destroy one; it sends no focus events,
    /// because the window's focus follows the shown workspace.
    private(set) var isParked = false

    /// Parks this content before its window shows another workspace.
    func park() { isParked = true }

    /// Shows this parked content again: its observation kept the tree current, so no re-map or apply.
    func unpark() { isParked = false }

    /// Installed: one topology (the coordinator restores its pane), whose ring draws in this frame.
    func didShow() {
        sendTopology()
        layoutView.syncWithModel()
    }

    init(workspace: WorkspaceModel, daemon: DaemonService, services: AppServices, state: WindowState) {
        self.workspace = workspace
        self.daemon = daemon
        self.services = services
        self.state = state
        focus = state.focus
        layoutModel.intentHandler = { [weak self] intent in self?.handle(intent) }
        _ = layoutView  // built here, then the bar and the content view, as before
        _ = screenBar
        _ = contentView
        let fallbackCreate = emptyWorkspaceRepair.create
        emptyWorkspaceRepair.createFirst = { [weak services, weak daemon] key in
            guard let services, let daemon, let workspace = daemon.store.workspaces.first(where: { $0.key == key }) else { throw DaemonError.notConnected }
            // Another machine's empty workspace gets a terminal: its chats start only when asked (cx-k21v).
            if services.agentTabs.opensFirstPage(on: daemon) {
                return try await services.agentTabs.openFirstPage(in: workspace, on: daemon, services: services)
            }
            return try await fallbackCreate(key)
        }
        emptyView = EmptyWorkspaceView(
            onNew: { [weak self] in self?.newFromEmptyState() }
        )
        themeScope.root(contentView)
        contentView.backgroundMenu = { [weak services, weak self] in
            services?.registry.makeContextMenu(for: .windowBackground, target: self.map { ActionTargetRef(kind: .workspace, id: $0.workspace.id) })
        }
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
            // A trigger: `applyCurrent` applies outside the stream too; `apply` compares with what it applied.
            for await result in ObservationStream({ ObservationTrigger(LayoutMapping.shared.map(workspace)) }) {
                self?.apply(result.value)
            }
        }
        // An empty workspace loaded while disconnected, or drawn from the
        // launch snapshot, is repaired once the daemon is back and its tree
        // is live, even if the tree itself does not change.
        let store = daemon.store
        connectionObservation = Task { [weak self] in
            for await _ in ObservationStream({ (String(describing: store.connectionState), store.isLoaded) }) {
                self?.repairIfEmpty()
            }
        }
        // A first terminal or a close that starts or ends while the
        // workspace is empty decides whether it shows its title; a first
        // terminal that failed adds why (cx-tzlqb).
        let repair = emptyWorkspaceRepair
        settlingObservation = Task { [weak self] in
            for await _ in ObservationStream({ workspace.key.map { "\($0.rawValue):\(repair.isSettling($0)):\(repair.failure($0) ?? "")" } ?? "" }) {
                self?.updateEmptyState()
            }
        }
        // Panes with an unread notification draw the attention ring.
        let notifications = services.notifications
        attentionObservation = Task { [weak self] in
            for await marks in ObservationStream({ notifications.attentionMarks(for: workspace) }) {
                guard let self else { return }
                if self.layoutModel.attention != marks { self.layoutModel.attention = marks }
            }
        }
    }

    /// Re-applies the current store state (after a command response that
    /// may trail its own delta).
    func applyCurrent() {
        apply(LayoutMapping.shared.map(workspace), force: true) // sends the topology again (unpark, expected focus)
    }

    private func apply(_ result: LayoutMapping.Result, force: Bool = false) {
        guard appliedTree.update(result, edgeDocks: daemon.supports(DaemonCapabilities.shared.edgeDocks), rows: daemon.supports(DaemonCapabilities.shared.rows)) || force else { return }
        #if DEBUG
        DebugLayoutCounters.workspaceApplies &+= 1
        #endif
        let wasApplying = isApplying
        isApplying = true
        defer { isApplying = wasApplying }
        handles = result.handles
        // A key the daemon's pane took over from a provisional one keeps its controller (cx-ry0y).
        for (id, controller) in panes {
            if let handle = handles.panes[id], let model = daemon.store.pane(handle) { controller.adopt(model) }
        }
        if layoutModel.acceptsEdgeDockDrops != appliedTree.edgeDocks { layoutModel.acceptsEdgeDockDrops = appliedTree.edgeDocks }
        if layoutModel.acceptsRowOps != appliedTree.rows { layoutModel.acceptsRowOps = appliedTree.rows } // no row op without rows-v1 (rows.md step 4)
        layoutModel.apply(screens: result.screens)
        #if DEBUG
        DebugLayoutCounters.notePanes(layoutModel.screens.reduce(0) { $0 + $1.layout.panes.count }, of: self)
        #endif
        // The view mounts the panes in this turn: a workspace shown now
        // draws its first frame with them, not one blank frame.
        layoutView.syncWithModel()
        updateEmptyState()
        repairIfEmpty()
        sendTopology()
        layoutView.syncWithModel() // focus the topology landed (a split's pane) rings in this frame
    }

    /// A workspace with no pane shows its title; Return creates the first
    /// terminal and focuses it when the daemon reports the surface. One that
    /// is settling (its first terminal on the way, or closing) shows nothing
    /// so the title does not flash before the tab strip and terminal land, or
    /// before the workspace closes.
    private func updateEmptyState() {
        let isEmpty = layoutModel.screens.allSatisfy { $0.layout.panes.isEmpty }
        let settling = workspace.key.map { emptyWorkspaceRepair.isSettling($0) } ?? false
        emptyView?.failure = workspace.key.flatMap { emptyWorkspaceRepair.failure($0) }
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
        let controller = PaneController(pane: model, daemon: daemon, layoutPaneID: pane, services: services, state: state, workspace: self)
        controller.view.toolbar = PaneToolbar(pane: controller) // the tab bar's hover "…" and pinned buttons
        controller.view.swapDrag = PaneSwapDrag(pane: controller)
        panes[pane] = controller
        services.paneMounts.changed()
        if !isApplying { sendTopology() }
        // Settings… asked before any window had a pane waits for the first one (R82). It opens
        // its tab after this layout pass, never inside it.
        if panes.count == 1, services.settingsWindow.isWaiting {
            let settings = services.settingsWindow
            Task { settings.windowDidShowContent() }
        }
        // So does the App Store (S22: never a window of its own).
        if panes.count == 1, services.apps.isStoreWaiting {
            let apps = services.apps
            Task { apps.windowDidShowContent() }
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
