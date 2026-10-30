import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextLayout
import CmuxNextPages
import CmuxNextWakeups
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
    private(set) lazy var layoutView = LayoutRootView(model: layoutModel, contentProvider: self, input: services.inputTap,
                                                       mainWork: services.mainWork, hiddenWork: services.hiddenLayoutWork)
    /// Layout plus the bottom screen bar; what the window shows.
    private(set) lazy var contentView = WorkspaceContentView(layoutView: layoutView, bar: screenBar.view)
    private(set) var emptyView: EmptyWorkspaceView?
    private(set) lazy var screenBar = ScreenBarController(content: self)
    /// The workspace theme: only this content area, under the window's
    /// room theme.
    let themeScope = ThemeScope(level: .workspace)
    unowned let services: AppServices
    let state: WindowState  // strong: a task holding this content past its window reads a live state; no cycle
    private(set) var handles = LayoutHandleMap()
    private(set) var panes: [LayoutPaneID: PaneController] = [:]
    /// The daemon tree, mapped to the layout: a service observation, as the handles must stay current and an
    /// empty workspace is repaired while it is off screen too (it records the layout for its show then).
    private var observation: ServiceObservation<ObservationTrigger<LayoutMapping.Result>>?
    /// Who caused the tree changes the observation applies (feature `automationBurstSnap`); nil: off.
    private var changeCauses: LayoutChangeCauses?
    /// The daemon's connection and first load: an empty workspace is repaired once its tree is live.
    private var connectionObservation: ServiceObservation<String>?
    /// The attention rings: drawn only while this content shows (``viewNode``).
    private var attentionObservation: VisibleObservation<[LayoutPaneID: AttentionMark]>?
    /// The empty state's title and failure: drawn only while this content shows (``viewNode``).
    private var settlingObservation: VisibleObservation<String>?
    /// Republishes `canvasLayout` when this workspace's active screen goes into or out of a canvas.
    private var canvasObservation: ServiceObservation<Bool>?
    /// True while `apply` mounts panes: it sends the topology once at its end,
    /// so a mount inside it does not rebuild the O(N) topology per pane (O(N^2)).
    private(set) var isApplying = false
    private var appliedTree = LayoutAppliedTree()
    /// The window's focus state machine (`WindowState.focus`,
    /// plans/cmux-next/focus.md). Every focus change in this content goes
    /// through it.
    let focus: FocusCoordinator
    // wall-clock: an id seed, not a time: Unix ms keeps ids from an earlier launch and the daemon's apart.
    var nextGestureTransaction: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) << 8
    /// The last key-turn pane create (Cmd-D's split, New Column, New Row) still sending: the next one sends after
    /// it, so one pressed on its stand-in names the daemon's pane (`createInKeysTurn`, `PaneHandlers.split`).
    var pendingCreate: ActionWork?
    /// Kept mounted off screen by its window (a workspace it showed): its panes report hidden, so
    /// their surfaces pause and only the warm set's LRU may destroy one; it sends no focus events,
    /// because the window's focus follows the shown workspace.
    private(set) var isParked = false
    /// When its window parked it (`WindowController.mountedContents` order).
    private(set) var parkedSerial: UInt64 = 0
    /// Parked and not on screen beside the shown workspace: it draws nothing, so its panes do no
    /// work for it (PL-script A2). They record what changed and show it once when it draws again
    /// (`PaneController.suspend` / `resume`). A companion on screen beside the shown workspace
    /// (`sidebar.multiView`) is parked but draws, so its panes keep working.
    private(set) var drawsNothing = false
    /// Parked and on no screen (not a `sidebar.multiView` companion beside the shown workspace).
    /// Its tree changes then update the model only: no layout, no view sync, no topology
    /// (CLAUDE.md "Go past Chrome where cmux is scripted"). Its root counts the passes it still gets then.
    private(set) var isOffScreen = false { didSet { layoutView.isOffScreen = isOffScreen } }
    /// The workspace's visibility node, under its window's, that its panes' nodes hang under
    /// (`PaneController`). nil until p06-scheduler-023 gives each mounted workspace its
    /// node (an unmounted workspace has none); until then each pane's node is a root.
    var visibilityNode: VisibilityNode? { nil }
    /// The node this content's view observations follow (the empty state, the attention rings): its workspace
    /// node once it has one, else its own root, which ``park(serial:)`` hides and ``unpark()`` and
    /// ``followAttention()`` show, as p06-scheduler-023 specifies for the workspace node.
    private lazy var viewNode: VisibilityNode = visibilityNode ?? VisibilityNode(root: "workspace-content", own: .visible)
    /// The latest mapping that came while off screen: applied once, at rest, when it shows (each a hidden apply).
    private var deferredApply: LayoutMapping.Result? { didSet { if deferredApply != nil { services.hiddenLayoutWork.noteApply() } } }
    /// Torn down (its window closed, or it unmounted to free memory): it mounts no pane, starts no
    /// observation and drives no repair or focus again, so a daemon reply or a repair that lands
    /// after the teardown leaves nothing behind. Chrome's WebContentsImpl stops
    /// its observers and drops its views at destruction the same way, so no late callback finds a
    /// half-live tab (content/browser/web_contents/web_contents_impl.cc, ~WebContentsImpl).
    private(set) var isTornDown = false
    /// Tab strip offsets a remount's record gave panes not mounted yet (`makeContentView` takes each).
    private var pendingTabStrips: [LayoutPaneID: CGFloat] = [:]

    /// Parks this content before its window shows another workspace. Its attention rings draw
    /// nothing while parked, so it stops following them (a global change wakes no parked workspace),
    /// and its layout changes wait until it shows (``apply(_:force:_:_:)``).
    func park(serial: UInt64) {
        guard !isTornDown else { return }
        parkedSerial = serial
        isParked = true
        isOffScreen = true
        viewNode.set(.hidden)
        setDrawsNothing(true)
    }

    /// Shows this parked content again, in this frame: the tree changes it skipped while off screen
    /// apply now in one step to their final state (its layout view is not live yet, so nothing
    /// animates a change nobody saw); then each pane maps its strip once and shows its selection
    /// (`PaneController.resume`), and the attention rings are read now and followed again.
    func unpark() {
        guard !isTornDown else { return }
        isParked = false
        comeOnScreen()
        setDrawsNothing(false)
        viewNode.set(.visible)
    }

    /// Parked but on screen beside the shown workspace (`sidebar.multiView`): it lays out what changed
    /// while it was off screen, its panes work again, and its attention rings draw, so it follows them.
    func followAttention() {
        guard !isTornDown else { return }
        comeOnScreen()
        setDrawsNothing(false)
        viewNode.set(.visible)
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
        guard !isTornDown else { return }
        sendTopology()
        layoutView.syncWithModel()
    }

    /// `parked`: mounted beside the shown workspace (`sidebar.multiView`), so its first apply sends the window no topology.
    /// `record`: the offsets the workspace showed when its window last unmounted it (`viewRecord()`), in place before
    /// the first frame commits.
    init(workspace: WorkspaceModel, daemon: DaemonService, services: AppServices, state: WindowState, parked: Bool = false,
         restoring record: WorkspaceViewRecord? = nil) {
        self.workspace = workspace
        isParked = parked
        self.daemon = daemon
        self.services = services
        self.state = state
        focus = state.focus
        layoutModel.intentHandler = { [weak self] intent in self?.handle(intent) }
        // An agent's or a script's burst of splits lands with no spring.
        if services.features.isEnabled(.automationBurstSnap) {
            layoutModel.snapsAutomationBursts = true
            changeCauses = LayoutChangeCauses(workspace, causes: services.mainWork.causes)
        }
        _ = layoutView  // built here, then the bar and the content view, as before
        // Divider, column-edge and row-edge drags move the layout once per frame (`pointerFrameDrags`), drawn resampled (`resampledDrags`).
        layoutView.setDragInput(frames: services.dragFrameInput, resampler: services.dragResampler)
        layoutView.resamplesStripPan = services.features.isEnabled(.stripPanResampling)
        // Content keeps its size through a pane spring (feature `paneHoldsContentInMotion`).
        layoutView.holdsContentInMotion = { [features = services.features] in features.isEnabled(.paneHoldsContentInMotion) }
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
            // So does every empty workspace in cmux Classic Mode (`tabs.terminalFirst`, #23021).
            if !NewTabKind.terminalFirst(services), services.agentTabs.opensFirstPage(on: daemon) {
                return try await services.agentTabs.openFirstPage(in: workspace, on: daemon, services: services)
            }
            return try await fallbackCreate(key)
        }
        emptyView = EmptyWorkspaceView(onNew: { [weak self] in self?.newFromEmptyState() })
        themeScope.root(contentView)
        contentView.backgroundMenu = { [weak services, weak self] in
            self.flatMap { services?.registry.makeContextMenu(for: .windowBackground, target: ActionTargetRef(kind: .workspace, id: $0.workspace.id)).themeRows(in: $0.themeScope.fullStrength) }
        }
        contentView.showsBar = screenBar.isVisible
        screenBar.onVisibilityChange = { [weak self] visible in self?.contentView.showsBar = visible }
        // Observation applies the first snapshot synchronously, including the empty-state view.
        observe()
        if let record { restoreScroll(record) }
    }

    // MARK: View record

    /// The offsets this content's views show that nothing else keeps, for a remount after `teardown`:
    /// where each scroll settles; a pane or screen not mounted yet keeps what its record gave it while
    /// the layout still has it. The selected tabs and the focused pane stay in the window's memory.
    func viewRecord() -> WorkspaceViewRecord {
        var record = WorkspaceViewRecord(screens: layoutView.scrollRecords())
        if !pendingTabStrips.isEmpty {
            let live = Set(layoutModel.screens.flatMap(\.layout.panes))
            for (id, offset) in pendingTabStrips where live.contains(id) { record.tabStrips[id] = offset }
        }
        for (id, controller) in panes {
            if let offset = WorkspaceViewRecord.stripOffset(controller.view.stripView.restorableScrollOffset) { record.tabStrips[id] = offset }
        }
        record.screenBar = WorkspaceViewRecord.stripOffset(screenBar.view.restorableScrollOffset)
        return record
    }

    /// The scrolls rest where the record says from the first layout at the window's size, which
    /// runs before the first frame commits; a pane mounted later takes its strip's when it mounts.
    private func restoreScroll(_ record: WorkspaceViewRecord) {
        layoutView.restoreScroll(record.screens)
        for (id, offset) in record.tabStrips {
            if let controller = panes[id] { controller.view.stripView.restoreScrollOffset(offset) } else { pendingTabStrips[id] = offset }
        }
        if let offset = record.screenBar { screenBar.view.restoreScrollOffset(offset) }
    }

    /// Ends everything this content started, so it and its views, panes and strips free after
    /// this turn (UnmountedWorkspaceLeavesNoObjectsTests): every observation stops (each holds its
    /// tracking until cancelled), a topology still queued for it is
    /// dropped (the coordinator keys it by object identity, which a later content may reuse), and
    /// every pane controller unregisters from the app's services. Idempotent.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        observation?.cancel()
        connectionObservation?.cancel()
        attentionObservation?.cancel()
        settlingObservation?.cancel()
        canvasObservation?.cancel()
        changeCauses?.cancel()
        focus.topologySent(by: self)
        screenBar.teardown()
        for controller in panes.values { controller.teardown() }
        if !panes.isEmpty {
            panes.removeAll()
            services.paneMounts.changed() // as `releaseContentView`: a pane left, its readers look again
        }
        pendingTabStrips.removeAll()
        contentView.removeFromSuperview()
    }

    private func observe() {
        let workspace = workspace, mainWork = services.mainWork
        // One mapping now (the first frame), tracked; each later batch of tree changes applies once, in a task
        // of its class (a person's in the input-response pass). A trigger: `applyCurrent` applies outside the
        // observation too; `apply` compares with what it applied. The observation has no cause of its own:
        // `changeCauses` names who made the changes it applies (none yet for the first mapping: `program`).
        observation = ServiceObservation(.visible, owner: "WorkspaceContent.tree", on: mainWork) {
            ObservationTrigger(LayoutMapping.shared.map(workspace))
        } apply: { [weak self] result in
            guard let self else { return }
            apply(result.value, cause: changeCauses?.take() ?? .program)
        }
        // An empty workspace loaded while disconnected, or drawn from the
        // launch snapshot, is repaired once the daemon is back and its tree
        // is live, even if the tree itself does not change.
        let store = daemon.store
        connectionObservation = ServiceObservation(.visible, owner: "WorkspaceContent.connection", on: mainWork) {
            "\(String(describing: store.connectionState)):\(store.isLoaded)"
        } apply: { [weak self] _ in
            self?.repairIfEmpty()
        }
        // A first terminal or a close that starts or ends while the
        // workspace is empty decides whether it shows its title; a first
        // terminal that failed adds why (cx-tzlqb).
        let repair = emptyWorkspaceRepair
        settlingObservation = VisibleObservation(viewNode, owner: "WorkspaceContent.emptyState", on: mainWork) {
            workspace.key.map { "\($0.rawValue):\(repair.isSettling($0)):\(repair.failure($0) ?? "")" } ?? ""
        } apply: { [weak self] _ in
            self?.updateEmptyState()
        }
        observeAttention()
        let layoutModel = layoutModel
        canvasObservation = ServiceObservation(.visible, owner: "WorkspaceContent.canvas", on: mainWork) {
            layoutModel.isCanvasActive
        } apply: { [weak self] _ in
            self?.services.canvasContextDidChange()
        }
    }

    /// Panes whose shown tab reads unread (a notification or Mark as Unread) draw the attention
    /// ring; this window's tab selection decides which tab a pane shows. Followed while this content
    /// shows (``viewNode``); a show reads the marks again in its turn.
    private func observeAttention() {
        let notifications = services.notifications, workspace = workspace
        let shownTab: @MainActor @Sendable (PaneModel) -> String? = { [weak self] pane in self?.panes[LayoutPaneID(pane.id)]?.stripModel.selectedID?.rawValue }
        attentionObservation = VisibleObservation(viewNode, owner: "WorkspaceContent.attention", on: services.mainWork) {
            notifications.attentionMarks(for: workspace, shownTab: shownTab)
        } apply: { [weak self] marks in
            guard let self, layoutModel.attention != marks else { return }
            // A ring read by going into its pane blinks out (classic's dismiss flash); one
            // cleared any other way fades. Set first, so the change that removes it sees it.
            let removed = Set(layoutModel.attention.keys).subtracting(marks.keys)
            layoutModel.attentionReadByEntry = notifications.takeEntryReads(removed: removed, in: workspace)
            layoutModel.attention = marks
        }
    }

    /// Re-applies the current store state (after a command response that
    /// may trail its own delta).
    func applyCurrent(_ file: StaticString = #fileID, _ line: UInt = #line) {
        // In the turn of the change it follows (an action's run, a command's reply): its cause too.
        let current = services.mainWork.causes.currentCause
        let cause = max(changeCauses?.take() ?? current, current)
        apply(LayoutMapping.shared.map(workspace), cause: cause, force: true, file, line) // after a command response that may trail its own delta
    }

    /// Applies the store's layout when it changed since the last apply (no-op otherwise): a pane whose tabs changed
    /// calls it first (`applyMovedTabs`), so a tab moved to a new pane shows there and leaves its old pane in one turn.
    func applyLayoutIfChanged() {
        apply(LayoutMapping.shared.map(workspace), cause: changeCauses?.take() ?? .program) // the cause the observation would apply
    }

    /// `cause`: who caused the change; an automation burst's structural change lands with no
    /// spring (`LayoutModel.apply(screens:cause:)`).
    private func apply(_ result: LayoutMapping.Result, cause: ObservationCause = .program, force: Bool = false,
                       _ file: StaticString = #fileID, _ line: UInt = #line) {
        guard !isTornDown else { return } // a reply that lands after teardown mounts no pane
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
                withApplying { syncStaleStrips() } // their topology parts go out in the one below
                sendTopology()
                layoutView.syncWithModel()
            }
            return
        }
        #if DEBUG
        DebugLayoutCounters.workspaceApplies &+= 1
        DebugLayoutCounters.note(force ? "apply(force)" : "apply", file, line)
        #endif
        let wasApplying = isApplying
        isApplying = true
        defer { isApplying = wasApplying }
        if layoutModel.acceptsEdgeDockDrops != appliedTree.edgeDocks { layoutModel.acceptsEdgeDockDrops = appliedTree.edgeDocks }
        if layoutModel.acceptsRowOps != appliedTree.rows { layoutModel.acceptsRowOps = appliedTree.rows } // no row op without rows-v1 (rows.md step 4)
        layoutModel.apply(screens: result.screens, cause: cause)
        #if DEBUG
        DebugLayoutCounters.notePanes(layoutModel.screens.reduce(0) { $0 + $1.layout.panes.count }, of: self)
        #endif
        // The view mounts the panes in this turn: a workspace shown now
        // draws its first frame with them, not one blank frame.
        layoutView.syncWithModel()
        updateEmptyState()
        repairIfEmpty()
        // Every strip matches the store before the topology: a moved tab is in its new pane only (not also in its
        // old pane's strip until that pane's own observation runs a turn later), so focus follows it in this turn.
        syncStaleStrips()
        // The one topology of this apply (mounts and pane snapshots inside it sent none).
        isApplying = wasApplying
        sendTopology()
        isApplying = true
        layoutView.syncWithModel() // focus the topology landed (a split's pane) rings in this frame
    }

    /// Runs `body` as part of an apply: pane changes inside it send no topology of their own (the caller sends one).
    func withApplying(_ body: () -> Void) {
        let wasApplying = isApplying
        isApplying = true
        defer { isApplying = wasApplying }
        body()
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
        guard !isTornDown else { return }
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
        guard !isTornDown, let handle = handles.panes[pane], let model = daemon.store.pane(handle) else { return NSView() }
        let controller = PaneController(pane: model, daemon: daemon, layoutPaneID: pane, services: services, state: state, workspace: self)
        controller.view.toolbar = PaneToolbar(pane: controller) // the tab bar's hover "…" and pinned buttons
        controller.view.swapDrag = PaneSwapDrag(pane: controller)
        panes[pane] = controller
        if let offset = pendingTabStrips.removeValue(forKey: pane) { controller.view.stripView.restoreScrollOffset(offset) }
        services.themes.applyPaneBackground(controller) // its own background and tint, before the first frame
        services.paneMounts.changed()
        sendTopology()
        // Settings… asked before any window had a pane waits for the first one (R82). It opens
        // its tab after this layout pass, never inside it.
        if panes.count == 1, services.settingsWindow.isWaiting {
            let settings = services.settingsWindow
            services.mainWork.post(.visible, owner: "SettingsWindow.firstPane") { settings.windowDidShowContent() }
        }
        // So does the App Store (S22: never a window of its own).
        if panes.count == 1, services.apps.isStoreWaiting {
            let apps = services.apps
            services.mainWork.post(.visible, owner: "AppStore.firstPane") { apps.windowDidShowContent() }
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
