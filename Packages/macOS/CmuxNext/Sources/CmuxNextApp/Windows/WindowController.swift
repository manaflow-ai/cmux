import AppKit
import CmuxNextAgentCursor
import CmuxNextAgentPane
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemonRecovery
import CmuxNextHistory
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextLayout
import CmuxNextWakeups
import Observation

/// One window: sidebar, titlebar, and the content of the workspace it shows.
/// Which workspace that is, plus frame and sidebar width, persist in the
/// daemon's personal projection through `WindowManager`.
final class WindowController: NSWindowController, NSWindowDelegate {
    var shortcutHints: WindowShortcutHints?
    let state: WindowState
    let sidebar: SidebarBridge
    let root: WindowRootView
    /// This window's focus state machine (plans/cmux-next/focus.md); it
    /// lives in the window's `WindowState`.
    var focus: FocusCoordinator { state.focus }
    /// Built in init (lazy because it holds self; no IUO).
    private(set) lazy var focusApplier = FocusEffectApplier(controller: self)
    private(set) var content: WorkspaceContentController?
    /// Every workspace this window showed, by id, kept mounted and paused (plans/cmux-next/tab-lifecycle.md):
    /// a switch back swaps its view in within the frame. Only its GPU surfaces leave, under the one memory
    /// budget (`SurfaceLedger`'s LRU of hidden surfaces); the tree, panes and strips stay (perf I6). With
    /// `memoryDiscardParkedWorkspaces` the app's `ParkedWorkspaceBudget` tears the least recently parked
    /// ones down past the Mac's budget or idle timeout (`WindowController+Parking`).
    /// With `sidebar.multiView` the ones `state.viewSet` shows beside `content` stay on screen (`arrangeOnScreen`).
    var parked: [String: WorkspaceContentController] = [:]
    /// Orders `parked` by when each was parked (`mountedContents`).
    var parkSerial: UInt64 = 0
    /// What each workspace this window unmounted showed (`releaseParked`), until it mounts again.
    var unmountedViews: [String: WorkspaceViewRecord] = [:]
    /// Times this window's workspace switches (`switch.workspace`): ``DebugWorkspaceSwitch/timer`` unless a test passes its own.
    var workspaceSwitchTimer = DebugWorkspaceSwitch.timer
    /// This window in the visibility tree, under the app's node: occlusion, miniaturize, a hidden
    /// app and sleeping displays feed it (`WindowVisibilitySource`). The parent
    /// of every mounted workspace's node.
    let visibility: VisibilityNode
    unowned let services: AppServices
    /// Shows the requested workspace, also while the window is hidden (`observeWorkspace`, WindowController+TopPage).
    var workspaceObservation: ServiceObservation<Void>?
    private var titleObservation: VisibleObservation<String>?
    private var startupObservation: VisibleObservation<DaemonStartupState>?
    /// Set by ``teardown()``: an observation that starts later does not start.
    var tornDown = false
    /// The room theme: every workspace without its own theme. The window's
    /// own chrome (sidebar, titlebar, backdrop) draws in the shown
    /// workspace's colors at any light/dark, so it matches the content beside
    /// it (with the color transition).
    let themeScope = ThemeScope(level: .room)
    var roomObservation: VisibleObservation<ProfileID>?
    var roomBrowserProfileObservation: ServiceObservation<BrowserProfileKey?>?
    /// Shown while the window has no workspace (first connect, or failure).
    private(set) var connectingView: DaemonConnectingView?
    /// What the window shows, for `debug.daemon`: `content` (a workspace), `connecting` (the connecting view) or `none`.
    var recoveryShows: String { content != nil ? "content" : connectingView != nil ? "connecting" : "none" }
    /// Agent cursors on this window's cursor layer (made on the first input it draws).
    private(set) lazy var agentCursor = AgentCursorWiring.slot(for: self)
    /// This window's clickable agent cursor tags (the overlay host holds it weakly).
    private(set) lazy var agentCursorTags = AgentCursorWindowTags(links: services.agentCursorTagLinks) { [weak self] in
        self?.agentCursor.stack?.host
    }
    /// This window's right sidebar (`WindowController+RightSidebar`).
    let rightSidebar: RightSidebarModel
    /// Its view, made the first time it shows.
    var rightSidebarView: RightSidebarView?
    /// This window's top pages (TOP-SECTION-ITEMS-ARE-PAGES), one view per route.
    private(set) lazy var topPages = TopPageHost(services: services, windowNode: visibility)

    /// - Parameter premade: The window to take instead of making one: the launch window that showed its saved
    ///   picture before this controller existed (`LaunchSnapshotWindow`).
    init(state: WindowState, services: AppServices, frame: NSRect?, window premade: ShellWindow? = nil) {
        self.state = state
        self.services = services
        let sidebar = SidebarBridge(services: services, state: state)
        self.sidebar = sidebar
        rightSidebar = RightSidebarModel(defaults: services.rightSidebarDefaults)
        SidebarProfileControl(services: services, state: state).install(model: sidebar.model, sidebar: sidebar.container.sidebarView)
        // The footer's Search button runs the one palette.open path (plans/cmux-next/sidebar-search.md).
        sidebar.container.sidebarView.onSearch = { [weak registry = services.registry] _ in
            _ = registry?.perform("palette.open", invocation: ActionInvocation(arguments: ["scope": .string("search")], origin: .user))
        }
        // The Energy Saver card's "Turn Off for Now" runs the palette's action.
        sidebar.container.sidebarView.onTurnOffEnergySaver = { [weak registry = services.registry] in
            _ = registry?.perform("energy.saver.turnOffForNow", invocation: ActionInvocation(origin: .user))
        }
        root = WindowRootView(sidebar: sidebar.container, revealDeadlines: services.mainDeadlines, signals: services.appearance, slideHoldsContent: WindowRootView.slideHoldsContent(in: services.features),
                              rendersMotionOnServer: { LayoutTunables.motionRenderServer.value })
        root.contentHost.hiddenDetach = services.makeHiddenWorkspaceDetach()
        // The static toggle runs the same action as the shortcut, palette and menu (R68).
        root.toolbarBand.onToggleSidebar = { [weak registry = services.registry] in
            _ = registry?.perform("toggleSidebar", invocation: ActionInvocation(origin: .user))
        }
        let window = premade ?? ShellWindow.main(frame: frame)
        window.zoomHoldsContent = services.features.isEnabled(.windowFrameAnimationHoldsContent)
        window.keyRouter = services.keyRouter
        // Before any view, overlay or panel of the window reads it; fixed for the process, as the backend is.
        window.pageSurface = services.chromiumRuntime.source.backend.pageSurface
        window.turnMeter = services.mainWork.budget.turns
        // Before any view reaches the window, so its views find this node under the app, not a root of their own.
        let node = services.appVisibility.windowNode(window, name: "window:\(state.id)")
        visibility = node
        root.follow(on: node, work: services.mainWork) // its settings follow while this window shows
        let registry = services.registry
        root.toolbarBand.follow(on: node, work: services.mainWork, title: { registry.descriptor(for: "toggleSidebar")?.title ?? "" },
                                shortcut: { registry.shortcutDisplay(for: "toggleSidebar") })
        super.init(window: window)
        installHistoryButtons()
        // The key tracker observes through the app's events before the
        // content's material views reach the window.
        WindowMaterialView.observeKeyFamily(of: window, through: services.appEvents)
        // Kind, scope and backdrop before the content view (the root paints
        // the backdrop: `WindowSurfacePainting`).
        window.install(kind: .main, content: root, scope: themeScope)
        // contentRect grows by the titlebar; restore the saved frame exactly.
        if let frame { window.setFrame(frame, display: false) } else { window.center() }
        window.delegate = self
        window.focus = focus
        focus.applier = focusApplier
        focus.window = window
        focus.crashKeys = services.crashKeys
        focus.keyInput = services.keyRouter.keyInput
        focus.inputDispatch = services.inputDispatch
        focus.personIntent = { [weak services, weak window] input in
            services?.keyRouter.creationInputCoordinator.personActed(in: window, event: input)
        }
        focus.send(.appActive(NSApp.isActive))
        startShortcutHints()
        observeRoom()
        observeSidebarHidden()
        followContentChanges()
        if rightSidebar.isVisible { showRightSidebar() }
        // From the next turn: the manager registers this window and shows its first workspace first. Behind the
        // launch picture the build starts it once its slices ran (`LaunchWindowBuild`).
        if premade == nil {
            services.mainWork.post(.visible, owner: "WindowController.followWorkspace") { [weak self] in self?.observeWorkspace() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func teardown() {
        tornDown = true
        services.keyRouter.creationInputCoordinator.windowClosed(window)
        stopShortcutHints()
        (window as? ShellWindow)?.overlayLayer.teardown()
        focusApplier.teardown()
        workspaceObservation?.cancel()
        sidebarObservation?.cancel()
        titleObservation?.cancel()
        startupObservation?.cancel()
        roomObservation?.cancel()
        roomBrowserProfileObservation?.cancel()
        state.roomBrowserProfileOf = nil
        content?.teardown()
        content = nil
        services.parkedWorkspaceBudget.forgetAll(in: self)
        parked.values.forEach { $0.teardown() }
        parked.removeAll()
        topPages.teardown()
        sidebar.teardown()
        visibility.detach()
    }

    // MARK: Workspace

    /// Shows the requested workspace on whichever machine holds it. While
    /// its Cloud machine is still connecting (relaunch), the window waits
    /// instead of replacing the request. A missing workspace falls back to
    /// the first one this window lists. There is no empty state: a window
    /// that loses its last workspace is closed by `WindowManager` in the
    /// same turn, before this observer runs. Until a workspace is mirrored
    /// (launch, a Cloud machine reconnecting) the connecting state shows.
    func showWorkspace(requested: String?) {
        let machines = services.machines
        // A parked workspace that closed, whose machine left, or that moved to another window goes now.
        let listed = Set(services.windows.registry.members(of: state.id))
        for (id, controller) in parked where !listed.contains(id) || machines.workspace(id: id)?.0 !== controller.workspace {
            discardParkedWorkspace(id)
        }
        if unmountedViews.keys.contains(where: { !listed.contains($0) }) { unmountedViews = unmountedViews.filter { listed.contains($0.key) } }
        if state.page.map(showTopPage) == true || showCreation() { return arrangeOnScreen() }
        if let requested, let (workspace, daemon) = machines.workspace(id: requested) {
            if !showsHomePage(instead: workspace) { show(workspace, on: daemon) }
            return
        }
        if requested != nil, state.machineID != MachineRegistry.localID, isWaiting(for: state.machineID) { return }
        let members = services.windows.registry.members(of: state.id)
        if let (workspace, daemon) = members.lazy.compactMap({ machines.workspace(id: $0) }).first {
            if !showsHomePage(instead: workspace) { show(workspace, on: daemon) }
            return
        }
        // Keep what is shown (the old content stays until the manager
        // closes or refills this window); a window with nothing yet waits.
        if content == nil { showConnecting() }
    }

    /// The local daemon's first connection, connecting or unavailable, until a workspace shows.
    private func showConnecting() {
        let view = connectingView ?? DaemonConnectingView(frame: .zero, recovery: services.daemon.recovery, node: visibility, on: services.mainWork,
                                                          deadlines: services.mainDeadlines)
        if connectingView == nil { DebugTimings.markLaunch("connecting_view_shown") }
        connectingView = view
        root.show(view)
        themeScope.show(nil)
        guard startupObservation == nil else { return }
        let daemon = services.daemon
        // Until a workspace shows (`show` drops it); a hidden window's view reads the state when it shows.
        startupObservation = VisibleObservation(visibility, owner: "WindowController.connecting", on: services.mainWork) {
            daemon.startup
        } apply: { [weak view] startup in
            view?.apply(startup)
        }
    }

    private func isWaiting(for machineID: String) -> Bool {
        guard services.cloud.isSignedIn || services.cloud.auth.isRestoring else { return false }
        guard services.cloud.hasLoadedMachines else { return true }
        guard let session = services.machines.session(machineID) else { return false }
        return session.machine.status.isLive && !session.daemon.store.isLoaded
    }

    private func show(_ workspace: WorkspaceModel, on daemon: DaemonService) {
        if state.workspaceID != workspace.id { state.workspaceID = workspace.id }
        if state.machineID != daemon.machineID { state.machineID = daemon.machineID }
        guard content?.workspace !== workspace else { DebugWorkspaceSwitch.unchanged(self); return arrangeOnScreen() }
        if let current = content { park(current) }
        DebugWorkspaceSwitch.mark(self, "park")
        let controller: WorkspaceContentController, kept = unpark(workspace.id)
        let unmounted = unmountedViews.removeValue(forKey: workspace.id)
        if let kept, kept.workspace === workspace, kept.daemon === daemon {
            controller = kept
            controller.unpark()
        } else {
            let record = kept?.viewRecord() ?? unmounted
            kept?.teardown()
            controller = WorkspaceContentController(workspace: workspace, daemon: daemon, services: services, state: state, restoring: record)
        }
        content = controller
        // One synchronous swap: the old view leaves (its panes stay mounted, paused) and the new
        // one draws in the same frame, its sidebar row already listed (a listed one pays no walk of every row) and selected.
        DebugWorkspaceSwitch.kind(self, controller === kept ? "warm" : "cold")
        DebugWorkspaceSwitch.mark(self, "content")
        sidebar.sameTurn.syncNow(rows: controller !== kept && !sidebar.model.lists(SidebarWorkspaceID(workspace.id)))
        DebugWorkspaceSwitch.mark(self, "sidebar")
        root.show(controller.contentView)
        DebugWorkspaceSwitch.mark(self, "root")
        arrangeOnScreen() // with `sidebar.multiView`, the workspaces shown beside it
        // The workspace's theme first, so the chrome repaints once: only the room's own views (sidebar,
        // titlebar, backdrop) run their theme hook, and their layer colors blend from the ones on
        // screen (appearance.colorTransition); the content swap itself never blends.
        services.themes.contentDidShow(controller)
        themeScope.show(controller.themeScope, animated: true)
        DebugWorkspaceSwitch.mark(self, "theme")
        startupObservation?.cancel()
        startupObservation = nil
        if connectingView != nil { DebugTimings.markLaunch("connecting_view_left") }
        connectingView = nil
        DebugTimings.markLaunch("workspace_content_shown")
        titleObservation?.cancel()
        // Named as its sidebar row is (`WorkspaceAutoNameReader.titlebarName`): a workspace on the
        // daemon's default name reads as its front tab (a torn-off chat's window read "workspace-41").
        let names = WorkspaceAutoNameWiring(services: services), selection = state.selection
        titleObservation = VisibleObservation(visibility, owner: "WindowController.title", on: services.mainWork) {
            names.reader.titlebarName(workspace) { selection.selection(in: $0.id) }
        } apply: { [weak self] title in
            self?.root.titlebar.title = title
        }
        // The new workspace's panes: the coordinator restores its pane and, now that the content is installed, re-applies it.
        controller.didShow()
        DebugWorkspaceSwitch.mark(self, "did_show")
        if let pane = focus.state.pane { focus.send(.contentPresented(pane: pane)) }
        services.windows.recordSaver.stateDidChange(state)
        services.cloudContextDidChange()
        services.canvasContextDidChange()
        services.windows.contentDidAppear(self)
        DebugWorkspaceSwitch.shown(self, in: window)
    }

    var focusedPane: PaneController? { content?.focusedPane }

    /// Parks the shown workspace (mounted, paused) while a top page fills the content area.
    func parkContentForPage() {
        titleObservation?.cancel()
        if let current = content { park(current) }
        content = nil
        arrangeOnScreen()
    }

    // MARK: NSWindowDelegate


    func windowDidBecomeKey(_ notification: Notification) {
        services.windows.didActivate(self)
        let snapshots = services.sidebarSnapshots, id = state.id
        services.work.task(.bestEffort) { await snapshots.touch(window: id) }
        focus.send(.windowKey(true))
        services.cloudContextDidChange()
        services.canvasContextDidChange()
    }

    func windowDidResignKey(_ notification: Notification) {
        focus.send(.windowKey(false))
        // Hover cards in other windows show this window's pages (R131). The
        // next key window is known on a later main-actor turn.
        services.mainWork.post(.visible, owner: "WindowController.resignKey") { [weak self] in
            guard let self, let window = self.window else { return }
            WindowKeyFamily.windowResignedKey(window, newKey: NSApp.keyWindow, owner: { $0.parent ?? $0.sheetParent },
                                              presenters: self.content?.panes.values.map { $0 as any SurfacePresenter } ?? [],
                                              cache: self.services.cache)
        }
    }

    func windowWillBeginSheet(_ notification: Notification) { focus.send(.overlayOpened(.sheet)) }
    func windowDidEndSheet(_ notification: Notification) { focus.send(.overlayClosed(.sheet)) }

    func windowDidMove(_ notification: Notification) { services.windows.recordSaver.geometryDidChange(state) }
    func windowDidEndLiveResize(_ notification: Notification) { services.windows.recordSaver.geometryDidChange(state) }

    var sidebarObservation: ServiceObservation<Bool>?


    /// Set once closing this incognito window was confirmed (or needed no
    /// confirmation).
    private var closeConfirmed = false

    /// Who asked for the close `windowShouldClose` is deciding: a close button or a key is the
    /// person's; ``performClose(by:)`` names an automation's for one call.
    private var closeOrigin: ActionOrigin = .user

    /// Closes the window as its close button does (the incognito check runs). Only the person's
    /// close fades (`WindowCloseMotion.isPersonsClose`): a scripted close is done when it returns.
    /// Never `performClose(_:)`: its button flash is a nested run loop of about 100 ms on the key turn
    /// (`NSWindow.closeWithoutButtonFlash()`).
    func performClose(by origin: ActionOrigin) {
        closeOrigin = origin
        defer { closeOrigin = .user }
        window?.closeWithoutButtonFlash()
    }

    /// An incognito window closes its workspaces: it asks first while one
    /// of its terminals runs a program (`IncognitoCloseConfirmation`).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let fades = WindowCloseMotion.isPersonsClose(closeOrigin)
        guard !closeConfirmed, services.windows.isIncognito(window: state.id) else { return !fadeOutThenClose(sender, fades: fades) }
        IncognitoCloseConfirmation.confirm(windows: [state.id], sheetOn: sender, services) { [weak self, weak sender] ok in
            guard ok, let self, let sender else { return }
            closeConfirmed = true
            if !fadeOutThenClose(sender, fades: fades) { sender.close() }
        }
        return false
    }

    /// The window fading out before it closes (`WindowCloseMotion`), from the person's close.
    private var closeMotion: WindowCloseMotion?

    /// Starts the person's close as a fade of the whole window; false when it closes now (Reduce
    /// Motion, not on screen, an automation's close, or a second close while it fades).
    private func fadeOutThenClose(_ window: NSWindow, fades: Bool) -> Bool {
        if let closeMotion {
            closeMotion.finish()
            return true
        }
        guard fades, WindowCloseMotion.fades(window) else { return false }
        let motion = WindowCloseMotion(window: window) { [weak window] in window?.close() }
        closeMotion = motion
        let next = NSApp.orderedWindows.first { $0 !== window && $0 is ShellWindow && $0.isVisible && !$0.isMiniaturized }
        motion.start(handingKeysTo: next)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        services.keyRouter.cancelChord()
        removeHistoryObserver()
        services.windows.windowWillClose(self)
    }
}

/// Runs tier 2 (content) shortcuts before the window's views (tiers 0 and 1
/// already ran app-wide in `CmuxApplication.sendEvent`, focus.md section 5),
/// reports every first-responder change to the window's focus coordinator
/// (`FocusResponderClassifier`), and keeps app overlays above Chromium page
/// windows (`WindowOverlayLayer`).
final class ShellWindow: NSWindow, OverlayPlaneHosting, BrowserWindowOcclusionProviding, TitlebarAccessoryHosting, WindowChromeHosting,
    CursorRectHoldHosting, TrafficLightsResting, ContentAreaMotionHosting, WindowZoomFinishing, WindowLayoutPassHosting, PageSurfaceHosting {
    /// Views that follow an ancestor's move read their place after each outermost layout pass (`layoutIfNeeded`).
    let layoutPasses = WindowLayoutPasses()
    /// The traffic lights' last windowed place: their left edge, their top's distance from the window's top,
    /// and their size (the window may come back from full screen at another height).
    private var windowedLights: (x: CGFloat, fromTop: CGFloat, size: CGSize)?
    /// Between `willExitFullScreen` and its end (WindowController+FullScreen).
    var isLeavingFullScreen = false

    /// Where the lights come back to while the window leaves full screen.
    var restingTrafficLights: CGRect? {
        guard isLeavingFullScreen, let windowedLights else { return nil }
        return CGRect(x: windowedLights.x, y: frame.height - windowedLights.fromTop - windowedLights.size.height,
                      width: windowedLights.size.width, height: windowedLights.size.height)
    }

    /// The root's layout reports the lights it found (window coordinates).
    func noteTrafficLights(_ lights: CGRect) {
        guard !styleMask.contains(.fullScreen), !isLeavingFullScreen else { return }
        windowedLights = (lights.minX, frame.height - lights.maxY, lights.size)
    }

    /// A pane policy that may hold cursor-rect invalidations (ShellWindow+Events.swift).
    weak var cursorRectHold: (any CursorRectHoldPolicy)?
    /// The incognito badge in the top row while the sidebar is hidden.
    var titlebarAccessoryFrame: CGRect? { (contentView as? WindowRootView)?.titlebarAccessoryFrame }
    var sidebarHidden: Bool { (contentView as? WindowRootView)?.sidebarHidden ?? false }

    weak var keyRouter: KeyRouter?
    weak var focus: FocusCoordinator?
    /// Where the window's Chromium pages draw (``PageSurfaceHosting``): set once by its controller at
    /// creation from the process's browser backend (``BrowserBackend/pageSurface``).
    var pageSurface: PageSurface = .childWindows
    /// The app's main run-loop turn meter: a layout depth counts only in the turn that began its pass.
    weak var turnMeter: MainTurnMeter?
    private(set) lazy var overlayLayer = WindowOverlayLayer(window: self) { [weak self] in self?.turnMeter?.turnNumber ?? 0 }

    /// Zoom without AppKit's blocking animation (``WindowZoom``): every entrypoint comes here.
    private var zoomState = WindowZoom()
    override func zoom(_ sender: Any?) { if !zoomState.zoom(self) { super.zoom(sender) } }
    /// Feature `windowFrameAnimationHoldsContent`: a zoom holds the window's terminal grids until it lands.
    var zoomHoldsContent: Bool {
        get { zoomState.holdsContent }
        set { zoomState.holdsContent = newValue }
    }
    override var isZoomed: Bool { zoomState.isZoomingIn ?? super.isZoomed }
    func windowZoomFinished(_ generation: Int) { zoomState.end(generation) }

    /// In an agent screenshot launch every frame stays on the test screen
    /// (`WindowPlacement.containedOnTestScreen`), whichever path sets it.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(WindowPlacement.containedOnTestScreen(frameRect), display: flag)
    }

    /// The traffic lights, found once (`StandardWindowButtons`, cx-8w027.25).
    private var standardButtons = StandardWindowButtons()
    override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? {
        if let button = standardButtons.cached(b, in: self) { return button }
        let button = super.standardWindowButton(b)
        standardButtons.store(button, for: b, in: self)
        return button
    }

    /// The display cycle's layout pass (`-[NSWindow layoutIfNeeded]`).
    /// Work that crosses windows (the overlay panel's planes, Chromium page
    /// windows, divider catcher panels) runs after the pass, never inside a
    /// view's `layout()`: changing another window or the child window order
    /// from inside layout re-marks this window and can loop until AppKit
    /// throws (2026-10-09 nightly crash). The overlay planes also re-read their home's place here, so a
    /// pane ring follows a pane that moved because an ancestor moved (sidebar width), not only its own layout.
    override func layoutIfNeeded() {
        #if DEBUG || CMUX_BENCH_HOOKS
        let traced = DebugWindowTransition.shared.isActive && overlayLayer.layoutDepth == 0
        let began = traced ? CACurrentMediaTime() : 0
        defer { if traced { DebugWindowTransition.shared.noteLayoutPass(self, seconds: CACurrentMediaTime() - began) } }
        #endif
        overlayLayer.windowWillLayout()
        super.layoutIfNeeded()
        // The outermost pass only, before the overlay layer's after-pass work (an occluder change it causes
        // joins that work); views that follow an ancestor's move hear didLayout before the queued blocks run.
        if overlayLayer.layoutDepth == 1 {
            (contentView as? WindowRootView)?.windowDidLayout()
            layoutPasses.didLayout()
            let blocks = pendingAfterLayout
            pendingAfterLayout.removeAll()
            for block in blocks { block() }
        }
        overlayLayer.windowDidLayout()
    }

    /// Inside `layoutIfNeeded` (views defer cross-window work to its end). The overlay layer counts a depth only
    /// in the turn that began the pass: after an exception AppKit caught skipped the end of a pass, the next
    /// turn's first pass is the outermost one again.
    var isInLayoutPass: Bool { overlayLayer.layoutDepth > 0 }

    private var pendingAfterLayout: [() -> Void] = []

    /// Runs `block` after the window's current layout pass, or now when no
    /// pass runs: for a view that must ask an ancestor for another layout
    /// from inside its own `layout()`.
    func afterLayoutPass(_ block: @escaping () -> Void) {
        if isInLayoutPass { pendingAfterLayout.append(block) } else { block() }
    }

    // MARK: OverlayPlaneHosting

    func adoptPlane(_ plane: OverlayPlane) { overlayLayer.adopt(plane) }
    func releasePlane(_ plane: OverlayPlane) { overlayLayer.release(plane) }
    func interactiveOverlayRectsDidChange(_ plane: OverlayPlane) { overlayLayer.interactiveRectsDidChange() }
    func planeDidLayout(_ plane: OverlayPlane) { overlayLayer.planeDidLayout(plane) }
    func paneShapesDidChange(_ plane: OverlayPlane) { overlayLayer.paneShapesDidChange() }

    // MARK: BrowserWindowOcclusionProviding

    /// Interactive overlays in the window, and occluders (the sidebar) that stay above pages.
    var browserOcclusionRectsInWindow: [CGRect] {
        overlayLayer.interactiveRects + (WindowOverlayHost.existingHost(for: self)?.occluderRects ?? [])
    }

    /// Nested `endEditing(for:)` calls, and whether a responder change waits for them to end (ShellWindow+Events.swift).
    var editTeardown = (depth: 0, pending: false)

    /// Nested order-ins of this window while it is not on screen (ShellWindow+Events.swift, `refusesOrderInKeyView`).
    var orderInDepth = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        // AppKit's own first key view while the window is placed on screen: the focus model places the keyboard.
        if refusesOrderInKeyView(responder) { return false }
        // Only a modal of the overlay top layer takes the window's keyboard (`WindowOverlayHost.refusesFirstResponder`).
        if WindowOverlayHost.existingHost(for: self)?.refusesFirstResponder(responder) == true { return false }
        if let controller = windowController as? WindowController, AgentPaneView.refusesSelfFocus(responder, inInputEvent: (NSApp as? CmuxApplication)?.isHandlingSendEvent() == true, focusModelApplies: controller.focus.isApplying, focusedPane: { controller.focus.currentState().pane }, pane: { if case .content(let pane) = FocusResponderClassifier.classify($0, in: controller) { pane } else { nil } }) { return false }
        let accepted = BenchSpans.measure("window.makeFirstResponder") { super.makeFirstResponder(responder) }
        if accepted { cursorRectHold?.firstResponderDidChange(in: self); BenchSpans.measure("focus.reportResponder") { reportResponder() } }
        return accepted
    }
}
