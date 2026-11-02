import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextPages
import CmuxNextWorkspaceRepair
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
    // A Command scroll over a Chromium page asks the page first (layout.pagesHandleCommandScroll).
    private(set) lazy var layoutView = LayoutRootView(model: layoutModel, contentProvider: self,
                                                      pageCommandScroll: services.cache.cef)
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
    /// Republishes `canvasLayout` when this workspace's active screen goes into or out of a canvas.
    private var canvasObservation: Task<Void, Never>?
    /// True while `apply` mounts panes: it sends the topology once at its end,
    /// so a mount inside it does not rebuild the O(N) topology per pane (O(N^2)).
    private(set) var isApplying = false
    private var appliedTree = LayoutAppliedTree()
    /// The window's focus state machine (`WindowState.focus`,
    /// plans/cmux-next/focus.md). Every focus change in this content goes
    /// through it.
    let focus: FocusCoordinator
    var nextGestureTransaction: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) << 8
    /// The last key-turn pane create (Cmd-D's split, New Column, New Row) still sending: the next one sends after
    /// it, so one pressed on its stand-in names the daemon's pane (`createInKeysTurn`, `PaneHandlers.split`).
    var pendingCreate: ActionWork?
    /// Kept mounted off screen by its window (a workspace it showed): its panes report hidden, so
    /// their surfaces pause and only the warm set's LRU may destroy one; it sends no focus events,
    /// because the window's focus follows the shown workspace.
    private(set) var isParked = false
    #if DEBUG
    /// This controller's share of `DebugLayoutCounters.workspaceApplies` and `.topologySends`: the
    /// process-wide counters also count every other workspace (tests run side by side).
    var debugApplies: UInt64 = 0
    var debugTopologySends: UInt64 = 0
    #endif
    /// When its window parked it (`WindowController.mountedContents` order).
    private(set) var parkedSerial: UInt64 = 0
    /// Parked and not on screen beside the shown workspace: it draws nothing, so its panes do no
    /// work for it (PL-script A2). They record what changed and show it once when it draws again
    /// (`PaneController.suspend` / `resume`). A companion on screen beside the shown workspace
    /// (`sidebar.multiView`) is parked but draws, so its panes keep working.
    private(set) var drawsNothing = false
    /// Parked and on no screen (not a `sidebar.multiView` companion beside the shown workspace).
    /// Its tree changes then update the model only: no layout, no view sync, no topology
    /// (CLAUDE.md "Go past Chrome where cmux is scripted").
    private(set) var isOffScreen = false
    /// The latest mapping that came while off screen: applied once, at rest, when it shows.
    private var deferredApply: LayoutMapping.Result?

    /// Parks this content before its window shows another workspace. Its attention rings draw
    /// nothing while parked, so it stops following them (a global change wakes no parked workspace),
    /// and its layout changes wait until it shows (``apply(_:force:_:_:)``).
    func park(serial: UInt64) {
        parkedSerial = serial
        isParked = true
        isOffScreen = true
        attentionObservation?.cancel()
        setDrawsNothing(true)
    }

    /// Shows this parked content again, in this frame: the tree changes it skipped while off screen
    /// apply now in one step to their final state (its layout view is not live yet, so nothing
    /// animates a change nobody saw); then each pane maps its strip once and shows its selection
    /// (`PaneController.resume`), and the attention rings are read now and followed again.
    func unpark() {
        isParked = false
        comeOnScreen()
        setDrawsNothing(false)
        observeAttention()
    }

    /// Parked but on screen beside the shown workspace (`sidebar.multiView`): it lays out what changed
    /// while it was off screen, its panes work again, and its attention rings draw, so it follows them.
    func followAttention() {
        comeOnScreen()
        setDrawsNothing(false)
        observeAttention()
    }

    private func comeOnScreen() {
        guard isOffScreen else { return }
        isOffScreen = false
        if let pending = deferredApply {
            deferredApply = nil
            apply(pending, force: true)
        }
    }

    /// Suspends or resumes every pane's strip and content work (`drawsNothing`).
    private func setDrawsNothing(_ value: Bool) {
        guard drawsNothing != value else { return }
        drawsNothing = value
        for controller in panes.values {
            if value { controller.suspend() } else { controller.resume() }
        }
    }

    /// Installed: one topology (the coordinator restores its pane), whose ring draws in this frame.
    func didShow() {
        sendTopology()
        layoutView.syncWithModel()
    }

    /// `parked`: mounted beside the shown workspace (`sidebar.multiView`), so its first apply sends the window no topology.
    init(workspace: WorkspaceModel, daemon: DaemonService, services: AppServices, state: WindowState, parked: Bool = false) {
        self.workspace = workspace
        isParked = parked
        self.daemon = daemon
        self.services = services
        self.state = state
        focus = state.focus
        layoutModel.intentHandler = { [weak self] intent in self?.handle(intent) }
        _ = layoutView  // built here, then the bar and the content view, as before
        // A scroll the layout took is timed as the layout's (`key.scroll_frame target=layout`).
        layoutView.onScrollTaken = { [inputDispatch = services.inputDispatch] in inputDispatch.noteLayoutTookScroll() }
        // A link dragged in from another app or a page: the drop zones a dragged tab has (LinkDropPlan).
        layoutView.linkDropHandler = { [weak self] url, target, perform in
            guard let self, let item = LinkDragItem(url, browserEnabled: LinkRouter.shared.routing().browserEnabled),
                  let plan = LinkDropPlan(target, takesTabs: { self.panes[$0]?.stripModel.showsNewTabButton == true }) else { return false }
            return !perform || self.services.linkOpener.drop(item, plan: plan, in: self)
        }
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
            self.flatMap { services?.registry.makeContextMenu(for: .windowBackground, target: ActionTargetRef(kind: .workspace, id: $0.workspace.id)).themeRows(in: $0.themeScope.fullStrength) }
        }
        contentView.showsBar = screenBar.isVisible
        screenBar.onVisibilityChange = { [weak self] visible in self?.contentView.showsBar = visible }
        // Observation applies the first snapshot synchronously, including the empty-state view.
        observe()
        // A Home with no pane yet is still being made (its dock, then the Chief conversation, over
        // several daemon replies): it stays clear until its conversation is in, never in pieces.
        if workspace.kind == "home", layoutModel.screens.allSatisfy({ $0.layout.panes.isEmpty }) {
            services.launchReveal.hold(contentView, until: .home)
        }
    }

    func teardown() {
        observation?.cancel()
        connectionObservation?.cancel()
        attentionObservation?.cancel()
        settlingObservation?.cancel()
        canvasObservation?.cancel()
        screenBar.teardown()
        for controller in panes.values { controller.teardown() }
        panes.removeAll()
        // A Home closed before its page came stops counting toward `.home`'s wait.
        services.launchReveal.release(contentView)
        contentView.removeFromSuperview()
    }

    private func observe() {
        let workspace = workspace
        // One mapping now (the first frame), tracked; the stream brings the later ones. A trigger:
        // `applyCurrent` applies outside the stream too; `apply` compares with what it applied.
        let (first, later) = ObservationStream.current({ ObservationTrigger(LayoutMapping.shared.map(workspace)) })
        observation = Task { [weak self] in
            for await result in later { self?.apply(result.value) }
        }
        apply(first.value)
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
        observeAttention()
        let layoutModel = layoutModel
        canvasObservation = Task { [weak self] in
            for await _ in ObservationStream({ layoutModel.isCanvasActive }) { self?.services.canvasContextDidChange() }
        }
    }

    /// Panes whose shown tab reads unread (a notification or Mark as Unread) draw the attention
    /// ring; this window's tab selection decides which tab a pane shows.
    private func observeAttention() {
        let notifications = services.notifications, workspace = workspace
        let shownTab: @MainActor @Sendable (PaneModel) -> String? = { [weak self] pane in self?.panes[LayoutPaneID(pane.id)]?.stripModel.selectedID?.rawValue }
        let marks = notifications.attentionMarks(for: workspace, shownTab: shownTab)
        if layoutModel.attention != marks { layoutModel.attention = marks }
        attentionObservation?.cancel()
        attentionObservation = Task { [weak self] in
            for await marks in ObservationStream({ notifications.attentionMarks(for: workspace, shownTab: shownTab) }) {
                guard let self else { return }
                guard self.layoutModel.attention != marks else { continue }
                // A ring read by going into its pane blinks out (classic's dismiss flash); one
                // cleared any other way fades. Set first, so the change that removes it sees it.
                let removed = Set(self.layoutModel.attention.keys).subtracting(marks.keys)
                self.layoutModel.attentionReadByEntry = notifications.takeEntryReads(removed: removed, in: workspace)
                self.layoutModel.attention = marks
            }
        }
    }

    /// Re-applies the current store state (after a command response that
    /// may trail its own delta).
    func applyCurrent(_ file: StaticString = #fileID, _ line: UInt = #line) {
        apply(LayoutMapping.shared.map(workspace), force: true, file, line) // after a command response that may trail its own delta
    }

    private func apply(_ result: LayoutMapping.Result, force: Bool = false, _ file: StaticString = #fileID, _ line: UInt = #line) {
        // Commands translate through the current handles even when the tree is unchanged (the
        // daemon's echo of an optimistic split renumbers only the new pane): no apply then.
        let topologyMoved = adoptHandles(result.handles)
        // Off screen: the handles stay current (commands translate through them) and an empty
        // workspace is still repaired; the layout waits for the frame that shows it.
        if isOffScreen {
            deferredApply = result
            repairIfEmpty()
            return
        }
        guard appliedTree.update(result, edgeDocks: daemon.supports(DaemonCapability.edgeDocks.rawValue), rows: daemon.supports(DaemonCapability.rows.rawValue)) || force else {
            if topologyMoved {
                // The one topology of this change (adoptions inside sent none); the focus it lands
                // rings in this frame.
                sendTopology()
                layoutView.syncWithModel()
            }
            return
        }
        #if DEBUG
        DebugLayoutCounters.workspaceApplies &+= 1
        debugApplies &+= 1
        DebugLayoutCounters.note(force ? "apply(force)" : "apply", file, line)
        #endif
        let wasApplying = isApplying
        isApplying = true
        defer { isApplying = wasApplying }
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
        // The one topology of this apply (mounts and pane snapshots inside it sent none).
        isApplying = wasApplying
        sendTopology()
        isApplying = true
        layoutView.syncWithModel() // focus the topology landed (a split's pane) rings in this frame
    }

    /// Takes the mapping's handles. A pane record a resync rebuilt under the same key keeps its
    /// controller, which moves to the new record (the echo of an optimistic split updates the
    /// provisional record in place, so it adopts nothing). True when the focus topology may have
    /// changed: a controller adopted, or a pane with no controller got a new handle (the
    /// topology reads its record through the handle). The adoptions send no topology themselves.
    private func adoptHandles(_ next: LayoutHandleMap) -> Bool {
        let wasApplying = isApplying
        isApplying = true
        defer { isApplying = wasApplying }
        var moved = false
        if handles != next {
            moved = next.panes.contains { id, handle in panes[id] == nil && handles.panes[id] != handle }
            handles = next
        }
        for (id, controller) in panes {
            guard let handle = handles.panes[id], let model = daemon.store.pane(handle), model !== controller.pane else { continue }
            controller.adopt(model)
            moved = true
        }
        return moved
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
            expectFocus(on: surface)
            applyCurrent()
        }
    }

    /// A lost terminal gets one replacement, focused when it lands.
    private func repairIfEmpty() {
        emptyWorkspaceRepair.check(workspace) { [weak self] surface in
            guard let self else { return }
            self.expectFocus(on: surface)
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
        services.themes.applyPaneBackground(controller) // its own background and tint, before the first frame
        services.paneMounts.changed()
        sendTopology()
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
        // So does a link from another app that waited for a workspace made to hold it (#27897):
        // the workspace shows before its first pane mounts.
        if panes.count == 1, !services.externalOpen.pending.isEmpty {
            let open = services.externalOpen
            Task { open.flush() }
        }
        return controller.view
    }

    func holdsContentInMotion(for pane: LayoutPaneID) -> Bool {
        guard let content = panes[pane]?.currentContent else { return false }
        if case .agent = content { return true }
        return false
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
