import AppKit
import CmuxNextAgentCursor
import CmuxNextActions
import CmuxNextHistory
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import Observation

/// One window: sidebar, titlebar, and the content of the workspace it shows.
/// Which workspace that is, plus frame and sidebar width, persist in the
/// daemon's personal projection through `WindowManager`.
final class WindowController: NSWindowController, NSWindowDelegate {
    let state: WindowState
    let sidebar: SidebarBridge
    let root: WindowRootView
    /// This window's focus state machine (plans/cmux-next/focus.md); it
    /// lives in the window's `WindowState`.
    var focus: FocusCoordinator { state.focus }
    private(set) var focusApplier: FocusEffectApplier!
    private(set) var content: WorkspaceContentController?
    /// Recently shown workspaces kept mounted and paused, oldest first
    /// (plans/cmux-next/tab-lifecycle.md): switching back to one swaps its
    /// view in within the frame, with no surface re-attach or blank frame.
    private(set) var parked: [WorkspaceContentController] = []
    private var parkedBudget = WarmSetBudget.standard
    unowned let services: AppServices
    private var workspaceObservation: Task<Void, Never>?
    private var titleObservation: Task<Void, Never>?
    private var startupObservation: Task<Void, Never>?
    /// The room theme: every workspace without its own theme. The window's
    /// own chrome (sidebar, titlebar, backdrop) draws in the shown
    /// workspace's colors when they share the room's light/dark mode, so it
    /// matches the content beside it without ever flipping the window light.
    let themeScope = ThemeScope(level: .room)
    private var roomObservation: Task<Void, Never>?
    /// Shown while the window has no workspace (first connect, or failure).
    private(set) var connectingView: DaemonConnectingView?
    /// Agent cursors on this window's cursor layer (made on the first input it draws).
    private(set) lazy var agentCursor = AgentCursorWiring.slot(for: self)

    init(state: WindowState, services: AppServices, frame: NSRect?) {
        self.state = state
        self.services = services
        let sidebar = SidebarBridge(services: services, state: state)
        self.sidebar = sidebar
        root = WindowRootView(sidebar: sidebar.container)
        root.dock.onActivate = { [weak sidebar] ref in sidebar?.activate(ref) }
        // The static toggle runs the same action as the shortcut, palette and menu (R68).
        root.toolbarBand.onToggleSidebar = { [weak registry = services.registry] in
            _ = registry?.perform("toggleSidebar", invocation: ActionInvocation(origin: .user))
        }
        let registry = services.registry
        root.toolbarBand.followToggleDescription(title: { registry.descriptor(for: "toggleSidebar")?.title ?? "" },
                                                 shortcut: { registry.shortcutDisplay(for: "toggleSidebar") })
        let window = ShellWindow(
            contentRect: frame ?? NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.keyRouter = services.keyRouter
        window.title = Strings.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        installHistoryButtons()
        // Kind, scope and backdrop before the content view (the root paints
        // the backdrop: `WindowSurfacePainting`).
        window.install(kind: .main, content: root, scope: themeScope)
        // contentRect grows by the titlebar; restore the saved frame exactly.
        if let frame { window.setFrame(frame, display: false) } else { window.center() }
        window.delegate = self
        window.focus = focus
        focusApplier = FocusEffectApplier(controller: self)
        focus.applier = focusApplier
        focus.send(.appActive(NSApp.isActive))
        observeWorkspace()
        observeRoom()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func teardown() {
        (window as? ShellWindow)?.overlayLayer.teardown()
        focusApplier.teardown()
        workspaceObservation?.cancel()
        badgeObservation?.cancel()
        titleObservation?.cancel()
        startupObservation?.cancel()
        roomObservation?.cancel()
        content?.teardown()
        content = nil
        parked.forEach { $0.teardown() }
        parked.removeAll()
        sidebar.teardown()
    }

    // MARK: Workspace

    /// The window recolors when it switches room.
    private func observeRoom() {
        let state = state
        roomObservation = Task { [weak self] in
            for await _ in Observations({ state.profileID }) {
                guard let self else { return }
                services.themes.windowDidChange(self)
            }
        }
    }

    /// The shown workspace and the parked ones, each with its theme scope.
    var mountedContents: [WorkspaceContentController] { (content.map { [$0] } ?? []) + parked }

    private func observeWorkspace() {
        let machines = services.machines
        let cloud = services.cloud!
        let windows = services.windows!
        let state = state
        workspaceObservation = Task { [weak self] in
            for await _ in Observations({ () -> [String] in
                // Re-run when the request or any machine's workspace list changes.
                [state.workspaceID ?? "", state.machineID, String(cloud.hasLoadedMachines)]
                    + windows.registry.members(of: state.id)
                    + machines.daemons.map { "\($0.machineID):\($0.store.isLoaded):\($0.store.workspaces.map(\.id))" }
            }) {
                self?.showWorkspace(requested: state.workspaceID)
            }
        }
    }

    /// Shows the requested workspace on whichever machine holds it. While
    /// its Cloud machine is still connecting (relaunch), the window waits
    /// instead of replacing the request. A missing workspace falls back to
    /// the first one this window lists. There is no empty state: a window
    /// that loses its last workspace is closed by `WindowManager` in the
    /// same turn, before this observer runs. Until a workspace is mirrored
    /// (launch, a Cloud machine reconnecting) the connecting state shows.
    private func showWorkspace(requested: String?) {
        let machines = services.machines
        // A parked workspace that closed (or whose machine left) goes now.
        parked.removeAll { controller in
            guard machines.workspace(id: controller.workspace.id)?.0 !== controller.workspace else { return false }
            controller.teardown()
            return true
        }
        if let requested, let (workspace, daemon) = machines.workspace(id: requested) {
            show(workspace, on: daemon)
            return
        }
        if requested != nil, state.machineID != MachineRegistry.localID, isWaiting(for: state.machineID) { return }
        let members = services.windows.registry.members(of: state.id)
        if let (workspace, daemon) = members.lazy.compactMap({ machines.workspace(id: $0) }).first {
            show(workspace, on: daemon)
            return
        }
        // Keep what is shown (the old content stays until the manager
        // closes or refills this window); a window with nothing yet waits.
        if content == nil { showConnecting() }
    }

    /// The connecting (or unavailable) state of the local daemon's first
    /// connection, until a workspace can be shown.
    private func showConnecting() {
        let view = connectingView ?? DaemonConnectingView(frame: .zero)
        connectingView = view
        root.show(view)
        themeScope.show(nil)
        guard startupObservation == nil else { return }
        let daemon = services.daemon
        startupObservation = Task { [weak self, weak view] in
            for await startup in Observations({ daemon.startup }) {
                view?.apply(startup)
                if self?.content != nil { return }
            }
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
        guard content?.workspace !== workspace else { return }
        if let current = content { park(current) }
        let controller: WorkspaceContentController
        if let index = parked.firstIndex(where: { $0.workspace === workspace && $0.daemon === daemon }) {
            controller = parked.remove(at: index)
            controller.unpark()
        } else {
            controller = WorkspaceContentController(workspace: workspace, daemon: daemon, services: services, state: state)
        }
        content = controller
        // One synchronous swap: the old view leaves (its panes stay mounted,
        // paused) and the new one draws in the same frame.
        root.show(controller.contentView)
        // The workspace's theme first, so the chrome repaints once; no
        // crossfade, which would fade the swap itself.
        services.themes.contentDidShow(controller)
        themeScope.show(controller.themeScope)
        trimParked()
        startupObservation?.cancel()
        startupObservation = nil
        connectingView = nil
        titleObservation?.cancel()
        titleObservation = Task { [weak self] in
            for await title in Observations({ workspace.displayName }) { self?.root.titlebar.title = title }
        }
        // The new workspace's panes: the coordinator restores its pane and,
        // now that the content is installed, re-applies it.
        controller.sendTopology()
        if let pane = focus.state.pane { focus.send(.contentPresented(pane: pane)) }
        services.windows.recordSaver.stateDidChange(state)
        services.cloudContextDidChange()
        services.windows.contentDidAppear(self)
    }

    var focusedPane: PaneController? { content?.focusedPane }

    // MARK: Parked workspaces

    private func park(_ controller: WorkspaceContentController) {
        controller.park()
        parked.removeAll { $0 === controller }
        parked.append(controller)
    }

    /// Memory pressure or the budget changed.
    func setParkedBudget(_ budget: WarmSetBudget) {
        parkedBudget = budget
        trimParked()
    }

    /// Drops the least recently shown parked workspaces until both the
    /// workspace count and their total panes fit the budget.
    private func trimParked() {
        var panes = parked.reduce(0) { $0 + $1.panes.count }
        while let oldest = parked.first, parked.count > parkedBudget.parkedWorkspaces || panes > parkedBudget.parkedPanes {
            panes -= oldest.panes.count
            parked.removeFirst().teardown()
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        services.windows.didActivate(self)
        let snapshots = services.sidebarSnapshots, id = state.id
        Task { await snapshots.touch(window: id) }
        focus.send(.windowKey(true))
        services.cloudContextDidChange()
    }

    func windowDidResignKey(_ notification: Notification) {
        focus.send(.windowKey(false))
        // Hover cards in other windows show this window's pages (R131). The
        // next key window is known on the next main-actor turn.
        Task { @MainActor [weak self] in
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

    private var badgeObservation: Task<Void, Never>?

    /// Marks this window incognito: the badge shows in the sidebar header,
    /// and in the top row after the traffic lights while the sidebar is
    /// hidden (strips under it start after it).
    func showIncognitoBadge() {
        sidebar.container.sidebarView.titlebarAccessory = IncognitoBadgeView()
        root.titlebarBadge = IncognitoBadgeView()
        let model = sidebar.model
        badgeObservation = Task { [weak self] in
            for await hidden in Observations({ model.isHidden }) {
                guard let self else { return }
                root.showsTitlebarBadge = hidden
                root.layoutSubtreeIfNeeded()
                for pane in content?.panes.values.map({ $0 }) ?? [] { pane.view.stripView.updateWindowControlsAvoidance() }
            }
        }
    }

    /// Set once closing this incognito window was confirmed (or needed no
    /// confirmation).
    private var closeConfirmed = false

    /// An incognito window closes its workspaces: it asks first while one
    /// of its terminals runs a program (`IncognitoCloseConfirmation`).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeConfirmed, services.windows.isIncognito(window: state.id) else { return true }
        IncognitoCloseConfirmation.confirm(windows: [state.id], sheetOn: sender, services) { [weak self, weak sender] ok in
            guard ok, let self else { return }
            closeConfirmed = true
            sender?.close()
        }
        return false
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
final class ShellWindow: NSWindow, OverlayPlaneHosting, BrowserWindowOcclusionProviding, TitlebarAccessoryHosting {
    /// The incognito badge in the top row while the sidebar is hidden.
    var titlebarAccessoryFrame: CGRect? { (contentView as? WindowRootView)?.titlebarAccessoryFrame }

    weak var keyRouter: KeyRouter?
    weak var focus: FocusCoordinator?
    private(set) lazy var overlayLayer = WindowOverlayLayer(window: self)

    /// In an agent screenshot launch every frame stays on the test screen
    /// (`WindowPlacement.containedOnTestScreen`), whichever path sets it.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(WindowPlacement.containedOnTestScreen(frameRect), display: flag)
    }

    /// The window's one titlebar decision (`TitlebarDragPolicy`): a left
    /// mouse-down in the band is delivered as usual, then moves the window
    /// (or runs the double-click action) only when the policy says so.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, TitlebarDragPolicy.decide(at: event.locationInWindow, in: self) == .movesWindow else {
            return super.sendEvent(event)
        }
        super.sendEvent(event)
        WindowTitlebar.handleMouseDown(event, in: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let keyRouter, let focus, keyRouter.routeContentKeyEquivalent(event, focus: focus.state) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// The Chromium fork adds each page window as a child ordered above
    /// everything, the overlay panel included. Lift the overlay (and the app
    /// panels above it) in the same call, before the window server shows a
    /// frame with the page over the focus ring; the notifications that
    /// follow the page would come a frame late.
    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        // Only the overlay host panel and page windows belong here (debug and test builds record the rest).
        ChildWindowPolicy.check(childWin, parent: self)
        super.addChildWindow(childWin, ordered: place)
        if WindowOverlayLayer.isContent(childWin) { overlayLayer.evaluate() }
        WindowOverlayHost.childWindowsDidChange(of: self)
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

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, let controller = windowController as? WindowController {
            controller.focus.responderDidChange(FocusResponderClassifier.classify(firstResponder, in: controller), source: .current)
        }
        return accepted
    }
}
