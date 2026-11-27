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
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextFocusUI
import CmuxNextLayout
import CmuxNextAppCore
import CmuxNextSettings

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
    /// The workspaces this window showed most recently (`ParkedWorkspaceBudget`), by id, kept mounted and paused
    /// (plans/cmux-next/tab-lifecycle.md): a switch back swaps its view in within the frame. Their GPU surfaces leave
    /// under the one memory budget (`SurfaceLedger`'s LRU of hidden surfaces); the tree, panes and strips stay (perf I6).
    /// With `sidebar.multiView` the ones `state.viewSet` shows beside `content` stay on screen (`arrangeOnScreen`).
    var parked: [String: WorkspaceContentController] = [:]
    /// Orders `parked` by when each was parked (`mountedContents`).
    var parkSerial: UInt64 = 0
    /// The next Cmd-N's view, built before the key in idle steps on the daemon's reserved workspace (its own slot).
    private(set) lazy var reservedContent = WorkspaceSpareSlot<WorkspaceContentController>(owner: "WorkspaceSpare", on: services.mainWork, wanted: { [weak self] in
        self.map { $0.services.windows.active === $0 && $0.content != nil && $0.services.daemon.reservesWorkspace && $0.services.windows.deferredWindows.isEmpty } ?? false
    }, reserve: { [weak self] in
        self.flatMap { $0.services.agentTabs.reserveWorkspace(on: $0.services.daemon, cwd: WorkspaceSpawn().startFolder(roomFolder: $0.services.machines.local.store.profile($0.state.profileID)?.defaults?.cwd, local: true, daemonDefault: NewTerminalStart.defaultFolder(on: $0.services.daemon))) }
    }, build: { [weak self] model in
        self.map { window in BenchSpans.measure("cmdN.reserved.build.init") { WorkspaceContentController(workspace: model, daemon: window.services.daemon, services: window.services, state: window.state, parked: true) } }
    }, mount: { [weak self] content in
        BenchSpans.measure("cmdN.reserved.build.mount") {
            guard let self else { return }
            content.contentView.setParked(true)
            self.root.contentHost.addPrewarmedSubview(content.contentView)
        }
    },
       teardown: { $0.teardown() }, workspace: { $0.workspace }, isReserved: { [weak self] in self?.services.daemon.store.reserves($0) ?? false })
    /// Workspaces Toggle Left/Right/Top/Bottom Dock created for an empty edge, docked there once the daemon reports
    /// them (`arrangeOnScreen`). In memory only.
    var pendingDocks: [String: DockEdge] = [:]
    /// The Chief panel's view (`WindowController+ChiefPanel`), made the first time it shows.
    var chiefPanelView: ChiefPanelView?
    /// A link clicked in the Chief while Home fills the window: until this instant, the next workspace shown gets
    /// the floating Chief (`openChiefPanelOnLeave(for:)`). In memory only.
    var chiefPanelArm: ContinuousClock.Instant?
    /// The view the panel holds, when not Home's Chief tab's (tests give a stand-in). Nil reads Home's.
    var chiefPanelSource: (@MainActor () -> NSView?)?
    unowned let services: AppServices
    private var workspaceObservation: Task<Void, Never>?
    private var titleObservation: Task<Void, Never>?
    private var startupObservation: Task<Void, Never>?
    /// The room theme: every workspace without its own theme. The window's
    /// own chrome (sidebar, titlebar, backdrop) draws in the shown
    /// workspace's colors at any light/dark, so it matches the content beside
    /// it (with the color transition).
    let themeScope = ThemeScope(level: .room)
    private var roomObservation: Task<Void, Never>?
    private var displayBackdropObservation: Task<Void, Never>?
    private var displayBackdrop: DisplayBackdropBinding?
    private var roomBrowserProfileObservation: Task<Void, Never>?
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
    /// A fullscreen page that has the whole screen (`WindowController+FullScreen`).
    var pagePresentation: BrowserPagePresentation?
    /// A full screen enter is under way (AppKit ignores a toggle until it ends).
    var isEnteringFullScreen = false
    /// The page that entered full screen left during the enter: the window leaves once it ends.
    var pageFullScreenExitPending = false
    /// This window's top pages (TOP-SECTION-ITEMS-ARE-PAGES), one view per route.
    private(set) lazy var topPages = TopPageHost(services: services)

    /// A new shell window's size (no saved frame).
    static let defaultSize = NSSize(width: 1100, height: 720)

    init(state: WindowState, services: AppServices, frame: NSRect?) {
        self.state = state
        self.services = services
        let sidebar = SidebarBridge(services: services, state: state)
        self.sidebar = sidebar
        SidebarProfileControl(services: services, state: state).install(model: sidebar.model, sidebar: sidebar.container.sidebarView)
        // The footer's Search button opens the Command Palette (Lawrence 2026-11-23: "we need some mechanism to
        // educate user about cmd shift p"): the press runs the same action as the shortcut, and the tooltip
        // shows its bound key (plans/cmux-next/sidebar-search.md).
        sidebar.container.sidebarView.onSearch = { [weak registry = services.registry] _ in
            _ = registry?.perform("commandPalette", invocation: ActionInvocation(origin: .user))
        }
        sidebar.container.sidebarView.followSearchShortcut { [registry = services.registry] in
            registry.shortcutDisplay(for: "commandPalette")
        }
        DebugTimings.markLaunch("window.sidebar_made"); root = WindowRootView(sidebar: sidebar.container, activeLook: services.activeLook) // startup-tti sub-marks
        services.wallpaperBadge.add(root.backdropView) // a live wallpaper's badge shows the signed-in account
        // The static toggle runs the same action as the shortcut, palette and menu (R68).
        root.toolbarBand.onToggleSidebar = { [weak registry = services.registry] in
            _ = registry?.perform("toggleSidebar", invocation: ActionInvocation(origin: .user))
        }
        let registry = services.registry
        root.toolbarBand.followToggleDescription(title: { registry.descriptor(for: "toggleSidebar")?.title ?? "" },
                                                 shortcut: { registry.shortcutDisplay(for: "toggleSidebar") })
        root.toolbarBand.appButtons = services.apps.client.toolbarButtons(in: root.toolbarBand, reveal: root.titlebarReveal, registry: services.registry)
        DebugTimings.markLaunch("window.root_made"); let window = ShellWindow(
            contentRect: frame ?? NSRect(origin: .zero, size: Self.defaultSize),
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
        super.init(window: window); DebugTimings.markLaunch("window.shell_made")
        installHistoryButtons()
        // Kind, scope and backdrop before the content view (the root paints
        // the backdrop: `WindowSurfacePainting`).
        window.install(kind: .main, content: root, scope: themeScope, activeLook: services.activeLook)
        // contentRect grows by the titlebar; restore the saved frame exactly.
        if let frame { window.setFrame(frame, display: false) } else { window.center() }
        window.delegate = self; DebugTimings.markLaunch("window.content_installed")
        let displayBackdrop = DisplayBackdropBinding(window: window, scope: themeScope,
                                                      displayID: { [weak window] in
                                                          window?.screen.flatMap(WindowPlacementFallback.displayID(of:))
                                                      })
        self.displayBackdrop = displayBackdrop
        if let settings = services.settings {
            displayBackdrop.apply(settings.snapshot.root)
            displayBackdropObservation = Task { [weak self, weak settings] in
                guard let settings else { return }
                for await root in ObservationStream({ settings.applied.root }) {
                    self?.displayBackdrop?.apply(root)
                }
            }
        }
        DebugTimings.markLaunch("window.backdrop_applied"); window.focus = focus
        window.focusLog = services.focusLog
        focus.applier = focusApplier
        focus.window = window
        focus.send(.appActive(services.appActiveSource()))
        startShortcutHints()
        observeWorkspace()
        observeRoom()
        observeSidebarHidden()
        observeWindowTitle()
        followContentChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func teardown() {
        services.keyRouter.creationInputCoordinator.windowClosed(window) // a new terminal's keyboard claim goes with it
        stopShortcutHints()
        (window as? ShellWindow)?.overlayLayer.teardown()
        focusApplier.teardown()
        workspaceObservation?.cancel()
        sidebarObservation?.cancel()
        titleObservation?.cancel()
        startupObservation?.cancel()
        roomObservation?.cancel()
        displayBackdropObservation?.cancel()
        displayBackdrop?.stop()
        displayBackdrop = nil
        roomBrowserProfileObservation?.cancel()
        state.roomBrowserProfileOf = nil
        content?.teardown()
        content = nil
        reservedContent.drop()
        parked.values.forEach { $0.teardown() }
        parked.removeAll()
        topPages.teardown()
        sidebar.teardown()
        // Last: a host the steps above made for the closing window (the overlay layer is made on
        // first use) closes its panel too, since it came after the close that tears hosts down.
        if let window { WindowOverlayHost.windowIsClosing(window); services.hoverCards.windowClosed(window) } // and its hidden sidebar's hold on cards
    }

    // MARK: Workspace

    /// The window recolors when it switches room.
    private func observeRoom() {
        let state = state
        roomObservation = Task { [weak self] in
            for await _ in ObservationStream({ state.profileID }) {
                guard let self else { return }
                services.themes.windowDidChange(self)
            }
        }
        // The room's browser profile for tab badges: set in the switch's own turn (`WindowState.profileID`),
        // and again when the room's record changes.
        let home = services.machines.local.store
        state.roomBrowserProfileOf = { [weak home] room in home?.profile(room)?.browserProfileID?.rawValue }
        roomBrowserProfileObservation = Task {
            for await _ in ObservationStream({ home.profile(state.profileID)?.browserProfileID }) { state.refreshRoomBrowserProfile() }
        }
    }

    private func observeWorkspace() {
        let machines = services.machines
        let cloud = services.cloud
        let windows = services.windows
        let state = state
        workspaceObservation = Task { [weak self] in
            for await _ in ObservationStream({ Self.readShowInputs(state, cloud: cloud, machines: machines, windows: windows) }) {
                self?.showWorkspace(requested: state.workspaceID)
                // A parked terminal (the classic migration's background workspaces) starts on its first show.
                if let id = state.workspaceID, let (workspace, daemon) = machines.workspace(id: id) { daemon.wakeParkedTabs(in: workspace) }
            }
        }
    }

    /// Native titles follow window state even before content mounts or while a top page covers it.
    private func observeWindowTitle() {
        titleObservation?.cancel()
        titleObservation = WindowListTitleObservation.start(values: { [weak self] in
            guard let self else { return (nil, nil, false, false) }
            let workspace = self.state.workspaceID.flatMap { self.services.machines.workspace(id: $0)?.0 }, names = WorkspaceAutoNameWiring(services: self.services, workspace: workspace)
            let title = workspace.map { names.reader.titlebarName($0) { self.state.selection.selection(in: $0.id) } }
            let local = self.services.machines.local, spaces = SidebarSpaceBar.profiles(local, window: self.state.id, windows: self.services.windows).count
            return (spaceName: spaces > 1 ? local.store.profile(self.state.profileID)?.name : nil, // the strip's rule: no space shows until a second
                    workspaceName: title, incognito: workspace.map { self.services.windows.isIncognito(workspace: $0) }
                        ?? self.services.windows.isIncognito(window: self.state.id),
                    showsWorkspaceChrome: self.state.page == nil && self.content != nil)
        }, fallbackName: Strings.appName, incognitoName: RoomStrings.incognitoName) { [weak self] title, workspace, showsChrome in
            self?.window?.title = title
            if showsChrome, let workspace { self?.root.titlebar.title = workspace }
        }
    }

    /// Reads what `showWorkspace` depends on (the request, each machine's workspace list): O(machines), no id list.
    private static func readShowInputs(_ state: WindowState, cloud: CloudService, machines: MachineRegistry, windows: WindowManager) {
        _ = (state.workspaceID, state.page, state.machineID, cloud.hasLoadedMachines, multiViewEnabled, LayoutTunables.dockedWorkspaces.value)
        _ = creationKey(state, cloud, machines)
        _ = windows.registry.members(of: state.id)
        for daemon in machines.daemons { _ = (daemon.store.isLoaded, daemon.store.workspaces.count) }
    }

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
        let unlisted = services.windows.registry.unlisted(parked.keys, in: state.id) // O(parked), never the window's whole list
        let guests = services.windows.registry.value.window(state.id)?.guests ?? [] // a guest that became this window's own, or the reverse, is built again
        if let content, content.isGuestView != guests.contains(content.workspace.id) { self.content = nil; content.teardown() }
        for (id, controller) in parked where unlisted.contains(id) || machines.workspace(id: id)?.0 !== controller.workspace || controller.isGuestView != guests.contains(id) {
            parked[id] = nil
            controller.teardown()
        }
        if state.page.map(showTopPage) == true || showCreation() { return arrangeOnScreen() }
        if let requested, let (workspace, daemon) = machines.workspace(id: requested) { return showsHomePage(instead: workspace) ? () : show(workspace, on: daemon) }
        if requested != nil, state.machineID != MachineRegistry.localID, isWaiting(for: state.machineID) || showPausedMachine(state.machineID) { return }
        if let requested, services.windows.claims.awaits(requested, in: state.id) { return content == nil ? showConnecting() : () }  // keeps the request
        let members = services.windows.registry.members(of: state.id)
        if let (workspace, daemon) = members.lazy.compactMap({ machines.workspace(id: $0) }).first { state.shownVia = "showWorkspace-fallback"; return showsHomePage(instead: workspace) ? () : show(workspace, on: daemon) }
        // Keep what is shown (it stays until the manager closes or refills this window); a window with nothing yet waits.
        if content == nil { showConnecting() }
    }

    /// The local daemon's first connection, connecting or unavailable, until a workspace shows.
    private func showConnecting() {
        let view = connectingView ?? DaemonConnectingView(frame: .zero, recovery: services.daemon.recovery)
        if connectingView == nil { DebugTimings.markLaunch("connecting_view_shown") }
        connectingView = view
        root.show(view)
        themeScope.show(nil)
        guard startupObservation == nil else { return }
        let daemon = services.daemon
        startupObservation = Task { [weak self, weak view] in
            for await startup in ObservationStream({ daemon.startup }) {
                view?.apply(startup)
                if self?.content != nil { return }
            }
        }
    }

    private func isWaiting(for machineID: String) -> Bool {
        let cloud = services.cloud, session = services.machines.session(machineID)
        return CloudWorkspaceWait(signedIn: cloud.isSignedIn || cloud.auth.isRestoring, machinesLoaded: cloud.hasLoadedMachines, machineLive: session?.machine.status.isLive, mirrored: session?.daemon.store.isLoaded == true).waits
    }

    private func show(_ workspace: WorkspaceModel, on daemon: DaemonService) {
        if state.workspaceID != workspace.id { state.workspaceID = workspace.id }
        if state.machineID != daemon.machineID { state.machineID = daemon.machineID }
        openChiefPanelOnLeave(for: workspace.id) // a link from the Chief (WindowDockFrame+ChiefPanel): the floating Chief
        guard content?.workspace !== workspace else { return arrangeOnScreen() }
        // Parking the current one never trims the one to show; a current one of the same id (a rebuilt model) is torn down below.
        if let current = content { park(current, leaving: workspace.id) }
        DebugWorkspaceSwitch.mark(self, "park")
        let reserved = parked[workspace.id] == nil ? reservedContent.take { $0.workspace === workspace } : nil // Cmd-N's, built before the key
        let controller: WorkspaceContentController, kept = parked.removeValue(forKey: workspace.id) ?? reserved
        if let kept, kept.workspace === workspace, kept.daemon === daemon {
            controller = kept
            controller.unpark()
        } else {
            kept?.teardown()
            controller = WorkspaceContentController(workspace: workspace, daemon: daemon, services: services, state: state)
        }
        content = controller
        // Panes pan and spring per display frame: shortcut chips over them follow.
        controller.layoutView.onFramePlaced = { [weak self] in self?.shortcutHints?.scrollDidChange() }
        // One synchronous swap: the old view leaves (its panes stay mounted, paused) and the new
        // one draws in the same frame, its sidebar row already listed (a listed one pays no walk of every row) and selected.
        DebugWorkspaceSwitch.kind(self, controller === reserved ? "reserved" : controller === kept ? "warm" : "cold")
        DebugWorkspaceSwitch.mark(self, "content")
        sidebar.sameTurn.syncNow(rows: sidebar.sameTurn.listsAnotherSpace(than: state.profileID.rawValue) || ((controller !== kept || controller === reserved) && !sidebar.model.lists(SidebarWorkspaceID(workspace.id))))
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
        observeWindowTitle()
        // The new workspace's panes: the coordinator restores its pane and, now that the content is installed, re-applies it.
        controller.didShow()
        DebugWorkspaceSwitch.mark(self, "did_show")
        if let pane = focus.state.pane { focus.send(.contentPresented(pane: pane)) }; controller.layoutModel.enterShownFocus() // its focused pane's ring is read now (cmux#46908)
        services.windows.recordSaver.stateDidChange(state)
        services.cloudContextDidChange()
        services.canvasContextDidChange()
        services.windows.contentDidAppear(self)
        DebugWorkspaceSwitch.shown(self, in: window, pages: controller.panes.values.compactMap { $0.stripModel.selectedID.flatMap { services.cache.browsers[$0.rawValue]?.tab } }.firstFrameColumns)
        revalidatePagePresentation()
        reservedContent.fill()
    }

    var focusedPane: PaneController? { content?.focusedPane }

    /// Parks the shown workspace (mounted, paused) while a top page fills the content area.
    func parkContentForPage() {
        if let current = content { park(current) }
        content = nil
        arrangeOnScreen()
        revalidatePagePresentation()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        services.windows.didActivate(self)
        services.hoverCards.windowOrderChanged() // this window came front: the card's cached top window may be under it
        reservedContent.fill { [weak self] in self?.services.windows.controllers.map(\.reservedContent) ?? [] } // follows the key main window
        let snapshots = services.sidebarSnapshots, id = state.id
        Task { await snapshots.touch(window: id) }
        focus.send(.windowKey(true))
        services.cloudContextDidChange()
        services.canvasContextDidChange()
        BackdropImageStore.shared.desktop.windowDidChange()
    }

    func windowDidResignKey(_ notification: Notification) {
        focus.send(.windowKey(false))
        // Hover cards in other windows show this window's pages (R131). The
        // next key window is known on the next main-actor turn.
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            self.services.notifications.focusDidSettle(self.focus.state, in: self) // the new key window may be its page's
            WindowKeyFamily.windowResignedKey(window, newKey: NSApp.keyWindow, owner: { $0.parent ?? $0.sheetParent },
                                              presenters: self.content?.panes.values.map { $0 as any SurfacePresenter } ?? [],
                                              cache: self.services.cache)
        }
    }

    func windowWillBeginSheet(_ notification: Notification) { focus.send(.overlayOpened(.sheet)) }
    func windowDidEndSheet(_ notification: Notification) { focus.send(.overlayClosed(.sheet)) }

    func windowDidMove(_ notification: Notification) { services.windows.recordSaver.geometryDidChange(state); BackdropImageStore.shared.light.windowDidMove() }
    func windowDidEndLiveResize(_ notification: Notification) { services.windows.recordSaver.geometryDidChange(state); BackdropImageStore.shared.light.windowDidMove() }
    /// A resize with no live resize (Zoom, macOS tiling, an Accessibility client such as Rectangle,
    /// a display change) keeps the origin and never ends a live resize: it saves here (#25568).
    func windowDidResize(_ notification: Notification) {
        guard window?.inLiveResize != true else { return }
        services.windows.recordSaver.geometryDidChange(state)
    }
    func windowDidChangeScreen(_ notification: Notification) {
        services.windows.recordSaver.geometryDidChange(state)
        BackdropImageStore.shared.desktop.windowDidChange()
    }
    /// Shown, unhidden or uncovered: the desktop picture behind it may be another one now, and tabs an agent drove off screen come back.
    func windowDidChangeOcclusionState(_ notification: Notification) { BackdropImageStore.shared.desktop.windowDidChange(); if let window { services.browserHost?.tabs.windowDidChangeOcclusion(window) }; services.windows.recordSaver.launchImages.windowsChanged() }

    var sidebarObservation: Task<Void, Never>?

    /// Set once closing this incognito window was confirmed (or needed no
    /// confirmation).
    private var closeConfirmed = false

    /// An incognito window closes its workspaces: it asks first while one
    /// of its terminals runs a program (`IncognitoCloseConfirmation`).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeConfirmed, services.windows.isIncognito(window: state.id) else { return !fadeOutThenClose(sender) }
        IncognitoCloseConfirmation.confirm(windows: [state.id], sheetOn: sender, services) { [weak self, weak sender] ok in
            guard ok, let self, let sender else { return }
            closeConfirmed = true
            if !fadeOutThenClose(sender) { sender.close() }
        }
        return false
    }

    /// The window fading out before it closes (`WindowCloseMotion`), from the person's close.
    private var closeMotion: WindowCloseMotion?

    /// Starts the person's close as a fade of the whole window; false when it closes now (Reduce
    /// Motion, not on screen, a second close while it fades, or the launch restore still runs).
    private func fadeOutThenClose(_ window: NSWindow) -> Bool {
        if let closeMotion {
            closeMotion.finish()
            return true
        }
        // Before the restore finished the close lands at once: a fade could outlive the restore,
        // which would then not know the window was closed and open it again.
        let windows = services.windows
        guard windows.restored, !windows.restoring, WindowCloseMotion.fades(window) else { return false }
        let motion = WindowCloseMotion(window: window) { [weak window] in window?.close() }
        closeMotion = motion
        let next = NSApp.orderedWindows.first { $0 !== window && $0 is ShellWindow && $0.isVisible && !$0.isMiniaturized }
        motion.start(handingKeysTo: next)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        pagePresentation = nil; chiefPanelView?.closeLauncher() // the floating Chief's own window goes with this one
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
final class ShellWindow: NSWindow, FocusRouting, OverlayPlaneHosting, BrowserWindowOcclusionProviding, TitlebarAccessoryHosting, WindowChromeHosting,
    CursorRectHoldHosting, TrafficLightsResting, ContentAreaMotionHosting, WindowZoomFinishing, WindowControlsAvoidanceHosting {
    /// The traffic lights' last windowed place (``WindowedTrafficLights``).
    private var windowedLights = WindowedTrafficLights()
    /// Between `willExitFullScreen` and its end (WindowController+FullScreen).
    var isLeavingFullScreen = false

    /// Where the lights come back to while the window leaves full screen.
    var restingTrafficLights: CGRect? { isLeavingFullScreen ? windowedLights.resting(windowHeight: frame.height) : nil }

    /// The root's layout reports the lights it found (window coordinates).
    func noteTrafficLights(_ lights: CGRect) {
        windowedLights.note(lights, windowHeight: frame.height, windowed: !styleMask.contains(.fullScreen) && !isLeavingFullScreen)
    }

    /// A pane policy that may hold cursor-rect invalidations (ShellWindow+Events.swift).
    weak var cursorRectHold: (any CursorRectHoldPolicy)?
    let presses = WindowPressRouter() // what a press does before AppKit gets it (ShellWindow+Events.swift)
    /// The incognito badge in the top row while the sidebar is hidden.
    var titlebarAccessoryFrame: CGRect? { (contentView as? WindowRootView)?.titlebarAccessoryFrame }
    var titlebarAccessoryReserve: CGRect? { (contentView as? WindowRootView)?.titlebarAccessoryReserve }
    var sidebarHidden: Bool { (contentView as? WindowRootView)?.sidebarHidden ?? false }
    /// Views that keep clear of the top row (Home's header in a pane with no tab bar): they
    /// re-check when the top row, the main pane card or a pane moves (`WindowController+Sidebar`).
    let windowControlsAvoiders = WindowControlsAvoiders()

    weak var keyRouter: KeyRouter?
    weak var focus: FocusCoordinator?
    weak var focusLog: FocusLog? // AppServices.focusLog: this window's focus changes, while it is on
    var routeInFlight: FocusRoute? // FocusRouting: the route of the move being made now
    private(set) lazy var overlayLayer = WindowOverlayLayer(window: self)

    /// Zoom without AppKit's blocking animation (``WindowZoom``): every entrypoint comes here.
    private let zoomState = WindowZoom()
    override func zoom(_ sender: Any?) { if !zoomState.zoom(self) { super.zoom(sender) } }
    override var isZoomed: Bool { zoomState.isZoomingIn ?? super.isZoomed }
    func windowZoomFinished(_ generation: Int) { zoomState.end(generation) }

    /// The smallest content a full-screen tile may give this window: the window's own minimum (`minSize`, the floor a
    /// person can resize it to), or a size set here. Without one AppKit derives it from the content's Auto Layout
    /// constraints after each change of the window's views (`_doUpdateTilingConstraintsImmediately`, a run loop
    /// observer), measuring every view in the window: about 3 ms of the main thread after each new tab, workspace or
    /// pane in a fleet sample (CMUX NEXT Stable perf gate, 2026-11-27).
    override var minFullScreenContentSize: NSSize {
        get { tileMinimum ?? contentRect(forFrameRect: NSRect(origin: .zero, size: minSize)).size }
        set { tileMinimum = newValue }
    }
    private var tileMinimum: NSSize?

    /// Every frame stays on the test screen in an agent screenshot launch, whichever path sets it
    /// (`WindowPlacement.containedOnTestScreen`), and is kept as given with no display (`constrainsToScreen`).
    override func setFrame(_ frameRect: NSRect, display flag: Bool) { super.setFrame(WindowPlacement.containedOnTestScreen(frameRect), display: flag) }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { WindowPlacement.constrainsToScreen ? super.constrainFrameRect(frameRect, to: screen) : frameRect }

    /// The traffic lights, found once (`StandardWindowButtons`, cx-8w027.25).
    private var standardButtons = StandardWindowButtons()
    override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? { // perf-hot: 1ms motion-frame
        if case .known(let button) = standardButtons.answer(b, in: self) { return button }
        let button = super.standardWindowButton(b)
        standardButtons.store(StandardWindowButtons.Found(button, for: b, in: self)) // Found reads AppKit before the store
        return button
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A panel over this window has the keys: no Ghostty keybind below (`KeyRouter.overlayHasKeys`).
        if !isKeyWindow, let focus, KeyRouter.overlayHasKeys(focus.state) { return false }
        if let keyRouter, let focus, let controller = windowController as? WindowController, keyRouter.routeContentKeyEquivalent(event, focus: focus.state, facts: keyRouter.facts(in: self, controller: controller)) { return true }
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
        ChromiumPageWindowMissionControl.keepOut(childWin) // a parked page's input window, 100 000 pt off, shrank Mission Control to nothing (cmux#48535)
        super.addChildWindow(childWin, ordered: place)
        if WindowOverlayLayer.isContent(childWin) { overlayLayer.evaluate() }
        WindowOverlayHost.childWindowsDidChange(of: self)
        if childWin.isChromiumPageWindow, let c = windowController as? WindowController { c.services.notifications.focusDidSettle(c.focus.state, in: c) } // a page window that took the keys first (a chat still loading) holds them only now, with no key change: look again (cmux#46908)
    }

    /// The display cycle's layout pass (`-[NSWindow layoutIfNeeded]`).
    /// Work that crosses windows (the overlay panel's planes, Chromium page
    /// windows, divider catcher panels) runs after the pass, never inside a
    /// view's `layout()`: changing another window or the child window order
    /// from inside layout re-marks this window and can loop until AppKit
    /// throws (2026-10-09 nightly crash). The overlay planes also re-read
    /// their home's place here, so a pane ring follows a pane that moved
    /// because an ancestor moved (sidebar width), not only its own layout.
    override func layoutIfNeeded() {
        #if DEBUG || CMUX_BENCH_HOOKS
        let traced = DebugWindowTransition.shared.isActive && overlayLayer.layoutDepth == 0
        let began = traced ? CACurrentMediaTime() : 0
        defer { if traced { DebugWindowTransition.shared.noteLayoutPass(self, seconds: CACurrentMediaTime() - began) } }
        #endif
        let layouts = LayoutPassGuard.shared.viewLayoutCalls // AppKit runs this pass before every display (each key): one that laid out no view moved no traffic light
        overlayLayer.windowWillLayout()
        super.layoutIfNeeded()
        // The outermost pass only, and before the overlay layer's own after-pass work, so an occluder change it causes joins that work.
        if overlayLayer.layoutDepth == 1 {
            (contentView as? WindowRootView)?.windowDidLayout(placesTrafficLights: !LayoutPassGuard.shared.isInstalled || LayoutPassGuard.shared.viewLayoutCalls != layouts)
            let blocks = pendingAfterLayout
            pendingAfterLayout.removeAll()
            for block in blocks { block() }
        }
        overlayLayer.windowDidLayout()
    }

    /// Inside `layoutIfNeeded` (views defer cross-window work to its end).
    /// The overlay layer's depth resets itself on the next event cycle if an
    /// exception AppKit caught skipped the end of a pass.
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
    func interactiveOverlayRectsDidChange(_ plane: OverlayPlane, shapesChanged: Bool) { overlayLayer.interactiveRectsDidChange(shapesChanged: shapesChanged) }
    func planeDidLayout(_ plane: OverlayPlane) { overlayLayer.planeDidLayout(plane) }
    func paneShapesDidChange(_ plane: OverlayPlane) { overlayLayer.paneShapesDidChange() }

    // MARK: BrowserWindowOcclusionProviding

    /// Interactive overlays in the window, and occluders (the sidebar) that stay above pages.
    var browserOcclusionRectsInWindow: [CGRect] {
        overlayLayer.interactiveRects + (WindowOverlayHost.existingHost(for: self)?.occluderRects ?? [])
    }

    /// Nested `endEditing(for:)` calls, and whether a responder change waits for them to end (ShellWindow+Events.swift).
    var editTeardown = (depth: 0, pending: false)

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let gate = ResponderMoveGate(window: self, log: focusLog, inInputEvent: (NSApp as? CmuxApplication)?.isHandlingSendEvent() == true, focusModelApplies: focus?.isApplying == true, route: routeInFlight)
        if gate.refuses(responder, or: { if let controller = windowController as? WindowController, AgentPaneView.refusesSelfFocus(responder, inInputEvent: gate.inInputEvent, focusModelApplies: controller.focus.isApplying, focusedPane: { controller.focus.currentState().pane }, pane: { if case .content(let pane) = FocusResponderClassifier.classify($0, in: controller) { pane } else { nil } }) { true } else { false } }) { return false }
        let accepted = holdingResponderReports { () -> Bool in let moved = BenchSpans.measure("window.makeFirstResponder") { super.makeFirstResponder(responder) }; editTeardown.pending = editTeardown.pending || moved; return moved }
        if accepted { cursorRectHold?.firstResponderDidChange(in: self); (windowController as? WindowController)?.chiefPanelView?.firstResponderDidChange(); gate.moved(to: firstResponder) }
        return accepted
    }
}
