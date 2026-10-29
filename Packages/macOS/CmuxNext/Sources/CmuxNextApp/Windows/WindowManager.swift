import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLaunch
import CmuxNextWakeups
import Observation

/// Opens, restores, closes, and persists windows.
///
/// Two kinds of state, two owners (user requirement 2026-09-29):
/// - `registry` (app-wide): which workspaces each window lists and which
///   windows exist. Transitions are in `WindowManager+Membership`.
/// - `WindowState` (one per window, in `states`): everything else the
///   window owns. Outlives its controller while the window is registered.
///
/// Controllers follow the registry declaratively (`sync`). A window exists
/// only while it owns a workspace (`WindowRegistry`); the one exception is
/// the launch window, which shows the daemon's connecting state before any
/// membership exists and is registered once it receives workspaces. Both persist in
/// the daemon's `personal` frontend projection (architecture.md 1), written
/// on every selection or focus change (geometry 500 ms after it settles)
/// and flushed on quit (WindowRecordSaver).
final class WindowManager {
    unowned let services: AppServices
    let registry = WindowRegistryStore()
    private(set) var controllers: [WindowController] = [] { didSet { services.background.windowsDidChange(); services.crashKeys?.noteWindows(controllers.count) } } // none left: background mode (cx-ghagp)
    /// Per-window state by window id, for every registered window.
    var states: [String: WindowState] = [:]
    private weak var lastActive: WindowController?
    /// The cmux window the event in dispatch came from (`dispatching(eventFrom:_:)`).
    var eventOrigin: EventOrigin?
    /// Called after a window is ordered in (the restart notice attaches).
    var onPresent: ((WindowController) -> Void)?
    /// Writes the window records (WindowRecordSaver).
    lazy var recordSaver = WindowRecordSaver(manager: self, deadlines: services.mainDeadlines)
    private var loadObservation: ServiceObservation<Bool>?
    var membershipObservation: ServiceObservation<[String]>?
    /// Records connected sessions in the home session (rooms, data-model.md 1.1).
    private(set) lazy var sessionRegistrar = SessionRegistrar(machines: services.machines, work: services.work, mainWork: services.mainWork)
    /// New workspaces a window asked for before the daemon reported them:
    /// reconcile places each in that window (opening it when it is not
    /// registered yet) and selects it.
    var pendingClaims: [String: String] = [:]
    /// Pending claims not to show on arrival; windows to open behind (automation, Option).
    var quietClaims: Set<String> = [], behindWindows: Set<String> = []
    /// Restored windows but the front one, not shown yet (`present`); `keepsOrder` while one shows alone.
    private var restacking: Set<String> = [], keepsOrder = false
    // memory: fixed one 32-byte CGRect per new window that waits for its claimed workspace (`claimNew`); `makeController` takes it when the window opens
    /// Frames for windows that open once their claimed workspace arrives.
    var pendingFrames: [String: CGRect] = [:]
    /// Sidebar slots for new workspaces, applied once the daemon reports
    /// them (`applyPendingPlacements`).
    var pendingPlacements: [String: PendingPlacement] = [:]
    /// Windows none of whose workspaces a machine reports yet (just created,
    /// or saved with workspaces that are gone or on a Cloud machine still
    /// connecting): kept off screen until their content is installed, so no
    /// window ever shows without a workspace. The value asks for
    /// bring-to-front on present.
    var awaitingContent: [String: Bool] = [:]
    /// Transitions that broke a window invariant (`WindowInvariants`).
    private(set) var invariantViolations = 0
    /// Machine each workspace was last seen on, to tell "gone" from "its
    /// machine is still connecting".
    var seenMachine: [String: String] = [:]
    /// Windows being closed by the registry (not by the user).
    var programmaticCloses: Set<String> = []
    private(set) var restored = false
    /// The windows the previous launch left open, captured at restore (Restore Previous App
    /// Launch reopens those closed since); nil before restore and when nothing was saved.
    var previousLaunch: PreviousLaunch?
    /// The window opened at launch before the saved state loaded: it shows the connecting state
    /// outside the registry, then becomes the frontmost restored window (or the window of the
    /// first workspaces). Nil once it is registered.
    var launchWindowID: String?
    /// The launch window waits for the launch snapshot's read (`restoreWhenLoaded`): a reopen meanwhile is answered by it.
    private(set) var launchWindowWaiting = false
    /// Windows placed by `TestWindowPlacement` so far (cascade ordinal).
    private var placedWindows = 0
    private(set) var isTerminating = false
    /// False in tests: windows are created but never ordered on screen.
    var ordersWindowsIn = true
    /// Restore finished: windows saved in full screen may enter it.
    var fullScreenRestoreReady = false
    /// The restored window entering full screen now (one at a time).
    var fullScreenRestore: RestoredFullScreen?
    var onFirstWindow: ((WindowController) -> Void)?
    /// The restore's and the visible panes' startup refs (p08-startup task 013), passed to `restoreWhenLoaded`.
    private var launchPaneRefs: VisiblePaneRefs?
    /// The restored windows behind the front one not built yet (`launchWindowsByOcclusion`):
    /// nil when every restored window was built in the restore's turn.
    private(set) var launchWindows: LaunchWindowQueue?
    /// Each waiting window's membership before its first change since restore: its selection repair waits
    /// for its build, which has the sidebar's drawn rows (close-focus.md).
    var waitingRepairs: [String: [String]] = [:]
    /// The launch window's saved picture as its first frame (`LaunchSnapshotWindow`); nil when the
    /// launch shows none.
    var launchPicture: LaunchPicturePhase?
    /// Work that waits for the launch's session restore (``whenRestored(_:)``); nil once it ran.
    private var restoreWaiters: [() -> Void]? = []
    /// A window installed workspace content (links opened at launch wait for it).
    var onContentDidAppear: ((WindowController) -> Void)?
    /// One-shot work for a workspace a reveal is still mounting, by window
    /// id; dropped when the window shows another workspace or closes.
    private var contentWaiters: [String: [(workspaceID: String, body: () -> Void)]] = [:]
    /// The incognito session's off-the-record browser profile while any
    /// incognito window is open (`WindowManager+Incognito`).
    var incognitoSession: BrowserProfileID?
    /// Workspaces of open incognito windows, closed at the next launch when
    /// this run ends without closing them. Built with the manager (in `AppServices.init`), so a read it
    /// starts itself is posted long before the launch window or the restore asks.
    let incognitoLedger: IncognitoWorkspaceLedger
    /// Incognito windows waiting for the ephemeral workspace created for
    /// them (`WindowManager+Ephemeral`).
    var pendingEphemeralWindows: [String] = []
    /// Incognito window of each tab it lists (`rememberIncognitoTabs`).
    var incognitoTabHomes: [String: String] = [:]
    /// Clears what the incognito session kept in memory (omnibar history).
    var incognitoHistoryReset: (() -> Void)?

    init(services: AppServices) {
        self.services = services
        incognitoLedger = .forApplication(bundleIdentifier: Bundle.main.bundleIdentifier,
                                          leftovers: services.environment.incognitoLeftovers, work: services.work)
        WindowActivation.didOrder = { [weak self] window, inFront in self?.windowDidOrder(window, inFront: inFront) }
    }

    /// The registry's recency (the window order, saved as `WindowRecord.order`) follows each order and key change.
    func windowDidOrder(_ window: NSWindow, inFront: Bool) {
        services.cache.hibernation?.windowsDidReorder() // an order without a key change posts nothing
        services.windowOcclusionFamilies?.windowsDidReorder()
        if inFront { eventDidBringForward(window) }
        guard !keepsOrder, let id = controllers.first(where: { $0.window === window })?.state.id else { return }
        registry.apply { if inFront { $0.activate(id) } else { $0.moveToBack(id) }; return WindowRegistry.Changes() }
    }

    /// The window actions without an explicit target act in: during an input event's dispatch the
    /// window the event came from (`dispatching(eventFrom:_:)`), else the key window's, else the
    /// last active one.
    var active: WindowController? {
        if let origin = eventOriginWindow { return origin }
        if let key = services.keyWindowSource(), let controller = owner(of: key) { return controller }
        return lastActive ?? controllers.first
    }

    /// The controller whose window is `window` or owns it: a sheet, a
    /// Chromium page window, the palette or another panel over it.
    func owner(of window: NSWindow) -> WindowController? {
        var current: NSWindow? = window
        while let candidate = current {
            if let controller = controllers.first(where: { $0.window === candidate }) { return controller }
            current = candidate.sheetParent ?? candidate.parent
        }
        return nil
    }

    func didActivate(_ controller: WindowController) {
        lastActive = controller
        if keepsOrder { return }
        registry.apply { $0.activate(controller.state.id); return WindowRegistry.Changes() }
    }

    /// Records invariant breaks found after a transition (a fault in debug
    /// builds). Nothing is repaired here, so a lifecycle bug stays visible.
    func noteInvariantViolations(_ problems: [String]) {
        invariantViolations += problems.count
        for problem in problems {
            #if DEBUG
            WindowInvariants.logger.fault("window invariant: \(problem, privacy: .public)")
            #else
            WindowInvariants.logger.error("window invariant: \(problem, privacy: .public)")
            #endif
        }
    }

    /// The controller of window `windowID` when it is built; never builds one, so reads (the palette's
    /// lists, observation passes, the window records) never build a restored window still waiting for
    /// its launch build (``launchWindows``). A window's state is in ``states`` built or not.
    func controller(for windowID: String) -> WindowController? {
        controllers.first { $0.state.id == windowID }
    }

    /// The controller of window `windowID`, built now when it is a restored window still waiting for its
    /// launch build: only for a person's or a script's act in that window (show, reveal, focus, reopen,
    /// a CLI target), as Chrome loads a restored tab once it is activated, ahead of its `TabLoader` turn
    /// (chrome/browser/sessions/tab_loader.cc).
    func controllerBuildingIfWaiting(for windowID: String) -> WindowController? {
        if let built = controller(for: windowID) { return built }
        guard launchWindows?.take(windowID) == true else { return nil }
        return buildWaitingWindow(windowID)
    }

    /// The window's state, created on first use.
    func state(for windowID: String) -> WindowState {
        if let state = states[windowID] { return state }
        let state = WindowState(id: windowID)
        states[windowID] = state
        return state
    }

    // MARK: Restore

    /// Opens one window once the launch snapshot's read has ended, never waiting (from the snapshot, else in the
    /// connecting state, outside the registry), then restores the saved
    /// windows once the first live snapshot arrives, the launch window
    /// becoming the frontmost. Creates a workspace only for an empty tree. `paneRefs` (the app's
    /// launch; nil in tests) are released at the end of the restore (`VisiblePaneRefs.finishRestore`).
    func restoreWhenLoaded(paneRefs: VisiblePaneRefs? = nil) {
        if let paneRefs { launchPaneRefs = paneRefs }
        registry.isLaunching = !restored
        launchWindowWaiting = true
        services.daemon.launchSnapshot.whenSettled { [weak self] in self?.openThenRestore() }
    }

    private func openThenRestore() {
        launchWindowWaiting = false
        LaunchSnapshotWindow(manager: self).openLaunchWindow()
        let store = services.daemon.store
        // The restore awaits the saved window state off main; `restore` runs once (`restored`).
        loadObservation = ServiceObservation(.visible, owner: "WindowManager.restoreWhenLoaded", on: services.mainWork) {
            store.isLoaded
        } apply: { [weak self] loaded in
            guard loaded, let self, !restored else { return }
            loadObservation?.cancel()
            // The restore adopts the launch window's controller, which a picture shown alone has not built yet.
            guard let launchPicture else { return startRestore() }
            launchPicture.whenBuilt { [weak self] in self?.startRestore() }
        }
    }

    private func startRestore() {
        services.work.task(.userBlocking) { [weak self] in await self?.restore() }
    }

    /// Runs `work` once the launch's session restore finished (the saved windows back, the launch window adopted or closed).
    func whenRestored(_ work: @escaping () -> Void) { if restoreWaiters == nil { work() } else { restoreWaiters?.append(work) } }

    private func restore() async {
        guard !restored else { return }
        restored = true
        registry.provisional = [:]
        DebugTimings.markLaunch("daemon_snapshot_loaded")
        var document = WindowStateDocument()
        if let windowState = services.daemon.windowState {
            document = (try? await windowState.load()) ?? WindowStateDocument()
        }
        // Incognito workspaces a crashed run left on a daemon without state
        // resources: the app's ledger owns them, so they close, never shown.
        // A daemon with state resources owns its ephemeral workspaces (it closes them at its
        // next start); until then they show in an incognito window only, so wait for its flags.
        let leftover = await incognitoLedger.load()
        if !leftover.isEmpty {
            registry.apply { $0.markDiscarding(leftover); return WindowRegistry.Changes() }
            discard(leftover)
        }
        await EphemeralWorkspaces.awaitFlags(self)
        let firstWorkspace = await FirstWorkspaceLaunch(manager: self).create(leftover: leftover)
        let restoredRegistry = WindowRegistry(records: document.windows)
        if !restoredRegistry.windows.isEmpty {
            previousLaunch = PreviousLaunch(windowIDs: restoredRegistry.recency.filter { restoredRegistry.window($0)?.isOpen == true },
                                            restoredAtMs: UInt64(max(0, Date().timeIntervalSince1970 * 1000))) // wall-clock: compared with the daemon's closedAtMs, Unix ms
        }
        let adopted = adoptLaunchWindow(restoredRegistry, records: document.windows)
        for record in document.windows where states[record.id] == nil { states[record.id] = WindowState(record: record) }
        if !restoredRegistry.windows.isEmpty {
            registry.apply { registry in
                registry = restoredRegistry
                return WindowRegistry.Changes()
            }
        }
        reconcileMembership()
        // Every remaining window closed (the open ones lost their workspaces while the app was
        // not running): the most recent one opens, so the app never starts with no window.
        if !registry.value.windows.isEmpty, !registry.value.windows.contains(where: \.isOpen), let front = registry.value.recency.first {
            registry.apply { $0.setRestored(front, open: true); return WindowRegistry.Changes() }
        }
        // Restored windows but the front one come back at their saved place, in any content arrival order.
        restacking = Set(registry.value.recency.filter { registry.value.window($0)?.isOpen == true }.dropFirst())
        scheduleLaunchBuilds()
        sync(previous: [:])
        // Registered now (it received workspaces): an ordinary window. If
        // it has none (the daemon failed to create one), it keeps showing
        // the startup state and is registered when workspaces arrive.
        if let launch = launchWindowID, registry.value.window(launch) != nil { launchWindowID = nil }
        // Other windows took every workspace: the unregistered launch window
        // has nothing to show and closes.
        if let launch = launchWindowID, !registry.value.windows.isEmpty, let controller = controller(for: launch) {
            launchWindowID = nil
            states[launch] = nil
            closeProgrammatically(controller)
        }
        // The adopted window is the frontmost saved one; keep it in front.
        if let adopted, controllers.count > 1 { present(adopted) }
        observeMembership()
        sessionRegistrar.start()
        registry.isLaunching = false
        fullScreenRestoreReady = true
        enterRestoredFullScreens()
        FirstWorkspaceLaunch(manager: self).land(firstWorkspace) // its New Tab page, not Home
        launchPaneRefs?.finishRestore(of: self)
        launchPaneRefs = nil
        let waiting = restoreWaiters ?? []
        restoreWaiters = nil
        for work in waiting { work() }
        // Classic cmux's session comes over once, after restore so the restored
        // registry never overwrites where its workspaces land.
        let onboarding = AppOnboardingServices(owner: services.onboarding)
        Task { await onboarding.migrateClassicAtLaunch(firstWorkspace: firstWorkspace) }
    }

    /// The restored windows behind the front one build by what shows of them, not all in the restore's
    /// turn (`launchWindowsByOcclusion`): one that no window in front covers, on a
    /// connected display, in its own afterFirstFrame post; a covered or off-screen one at afterStartup.
    /// The front window (the adopted launch window, else the first open one) builds now, and so does a
    /// window saved in full screen: it enters full screen once restore finished, which moves the display
    /// to its Space, so it does that at launch, never later under a person already at work.
    ///
    /// - Parameters:
    ///   - screens: The connected displays' frames.
    ///   - appHidden: Whether the app is hidden (nothing shows).
    func scheduleLaunchBuilds(screens: [CGRect] = NSScreen.screens.map(\.frame), appHidden: Bool = NSApp.isHidden) {
        guard services.features.isEnabled(.launchWindowsByOcclusion), services.environment.testWindow == nil,
              let startup = services.launchStartup else { return }
        let value = registry.value
        let open = value.recency.compactMap { value.window($0) }.filter(\.isOpen)
        let live = open.map(\.id).filter { self.controller(for: $0) != nil }
        var built = Set(live.isEmpty ? open.prefix(1).map(\.id) : live)
        built.formUnion(open.lazy.map(\.id).filter { self.states[$0]?.restoresFullScreen == true })
        let saved = open.map { window in
            LaunchWindowVisibility.Saved(id: window.id, frame: window.frame.map { WindowPlacementFallback.visible($0, display: window.display) },
                                         onActiveSpace: states[window.id]?.restoresFullScreen != true)
        }
        let visibility = LaunchWindowVisibility(screens: screens, rule: WindowOcclusionRule(appHidden: appHidden))
        let queue = launchWindows ?? LaunchWindowQueue(startup: startup) { [weak self] id in self?.buildLaunchWindow(id) }
        if queue.schedule(visibility.split(saved, built: built)) { launchWindows = queue }
    }

    /// A restored window's launch post: builds it unless it closed or was built meanwhile.
    private func buildLaunchWindow(_ id: String) {
        guard controller(for: id) == nil else { return }
        buildWaitingWindow(id)
    }

    /// Builds a restored window that waited for its launch build, then repairs its selection with its
    /// sidebar's drawn rows, the repair ``repairSelections(previous:preferred:)`` left for it.
    @discardableResult
    private func buildWaitingWindow(_ id: String) -> WindowController? {
        let previous = waitingRepairs.removeValue(forKey: id)
        guard let window = registry.value.window(id), window.isOpen else { return nil }
        let controller = makeController(for: window)
        let shown = controller.state.workspaceID
        repairSelection(of: window, previous: previous ?? window.workspaceIDs)
        if controller.state.workspaceID != shown { controller.showWorkspace(requested: controller.state.workspaceID) }
        return controller
    }

    /// The launch window takes the frontmost saved window's identity and
    /// state, so relaunch shows it without opening a second window. With
    /// nothing saved it stays the only window and receives every workspace.
    private func adoptLaunchWindow(_ restored: WindowRegistry, records: [WindowRecord]) -> WindowController? {
        // The frontmost saved window that can show a workspace now; one whose
        // workspaces are gone or still connecting would leave the launch
        // window on screen with nothing to show.
        guard let launchID = launchWindowID, let launch = controller(for: launchID),
              let front = restored.recency.first(where: { id in
                  restored.window(id).map { $0.isOpen && hasMirroredWorkspace($0) } == true
              }),
              let record = records.first(where: { $0.id == front }) else { return nil }
        launch.state.adopt(record)
        launchWindowID = front
        states[launchID] = nil
        states[front] = launch.state
        launch.sidebar.restore(width: record.sidebarWidth, hidden: record.sidebarHidden)
        if services.environment.testWindow == nil, let frame = restored.window(front)?.frame {
            launch.window?.setFrame(WindowPlacementFallback.visible(frame, display: restored.window(front)?.display), display: true)
        }
        return launch
    }

    // MARK: Controllers

    /// Creates the controller of registered window `id`, in `premade` when the launch showed that window's saved
    /// picture before it had a controller (`LaunchSnapshotWindow`).
    @discardableResult
    func makeController(for window: WindowRegistry.Window, in premade: ShellWindow? = nil) -> WindowController {
        let state = state(for: window.id)
        if state.machineID != MachineRegistry.localID { services.cloudNeeded() }  // a Cloud machine's window, restored ones too
        var frame = (window.frame ?? pendingFrames.removeValue(forKey: window.id)).map { WindowPlacementFallback.visible($0, display: window.display) }
        let placement = services.environment.testWindow
        if let placement, let placed = placement.windowFrame(ordinal: placedWindows, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            frame = placed
            placedWindows += 1
        }
        let controller = WindowController(state: state, services: services, frame: frame, window: premade)
        controller.focus.overlayChanges = services.overlayChanges
        if let window = controller.window { WindowOverlayHost.host(for: window).changes = services.overlayChanges }
        controller.sidebar.restore(width: state.sidebarWidth, hidden: state.sidebarHidden)
        if registry.value.isIncognito(window.id) { controller.showIncognitoBadge() }
        SidebarTabRowHandoff.install(on: controller, session: services.dragSession)
        controllers.append(controller)
        // Its content goes in before it is ordered in (the launch snapshot's workspace, else the connecting state), so
        // its first frame on screen draws it, never the backdrop alone; the controller's own observer would install
        // it a main-actor hop later. The launch picture's window is on screen already, its picture over it: its
        // content is built behind the picture in slices (`LaunchSnapshotWindow`).
        if premade == nil { controller.showWorkspace(requested: state.workspaceID) }
        // A window none of whose workspaces is mirrored yet stays off screen until `contentDidAppear` (never an
        // empty frame). The launch window (no workspaces) shows the connecting state at once.
        if premade != nil || controller.content != nil || hasMirroredWorkspace(window) || window.workspaceIDs.isEmpty {
            present(controller)
        } else {
            awaitingContent[window.id] = false
        }
        if controllers.count == 1 { onFirstWindow?(controller) }
        return controller
    }


    /// True when a machine reports at least one of `window`'s workspaces.
    func hasMirroredWorkspace(_ window: WindowRegistry.Window) -> Bool {
        window.workspaceIDs.contains { services.machines.workspace(id: $0) != nil }
    }

    /// Runs `body` once `controller` next shows a workspace, if that is
    /// `workspaceID`.
    /// `body` keeps the view-change permission of the run that called this.
    func afterNextContent(in controller: WindowController, showing workspaceID: String, _ body: @escaping () -> Void) {
        let run = ActionRunScope.current
        contentWaiters[controller.state.id, default: []].append((workspaceID, { ActionRunScope.carrying(run, body) }))
    }

    /// The window installed its first workspace content: a window kept off
    /// screen for it is ordered in now.
    func contentDidAppear(_ controller: WindowController) {
        defer {
            onContentDidAppear?(controller)
            let shown = controller.content?.workspace.id
            for waiter in contentWaiters.removeValue(forKey: controller.state.id) ?? [] where waiter.workspaceID == shown {
                waiter.body()
            }
        }
        guard let front = awaitingContent.removeValue(forKey: controller.state.id) else { return }
        present(controller)
        if front { bringToFront(controller) }
    }

    /// Orders a new window in without taking focus under no-activate.
    private func present(_ controller: WindowController) {
        // Tests: never on the user's display. Otherwise one rule: under
        // no-activate behind the others (in front on a test screen), never key.
        let behind = behindWindows.remove(controller.state.id) != nil
        services.background.windowWillAppear(activates: !behind && ordersWindowsIn) // leave background mode first (cx-ghagp)
        let restacks = restacking.remove(controller.state.id) != nil
        if ordersWindowsIn, let window = controller.window,
           !(restacks && WindowActivation.restack(window, in: registry.value.recency.map { self.controller(for: $0)?.window })) {
            // A restored window shown alone comes forward without key; the order keeps its saved place.
            let kept = keepsOrder
            keepsOrder = restacks
            WindowActivation.show(window, restacks ? .bringForward : behind ? .presentBehind : .present)
            keepsOrder = kept
            DebugTimings.markLaunch("window_display") // first on screen: Chrome's RecordBrowserWindowDisplay (BrowserView::Show)
        }
        onPresent?(controller)
        enterRestoredFullScreens()
    }

    /// Brings a window forward (not key and no activation under
    /// `CMUX_NEXT_NO_ACTIVATE=1`).
    /// An action run without view-change permission brings nothing forward.
    func bringToFront(_ controller: WindowController) {
        guard ActionRunScope.viewChangeAllowed() else { return }
        if awaitingContent[controller.state.id] != nil {
            awaitingContent[controller.state.id] = true
            return
        }
        guard ordersWindowsIn, let window = controller.window else { return }
        WindowActivation.show(window, .raise)
    }

    func windowWillClose(_ controller: WindowController) {
        let id = controller.state.id
        controllers.removeAll { $0 === controller }
        if lastActive === controller { lastActive = nil } // S22: a closed window is never active, even if retained.
        awaitingContent[id] = nil
        contentWaiters[id] = nil
        restacking.remove(id)
        services.pagePreloads.windowWillClose(controller.window)
        controller.teardown()
        if programmaticCloses.remove(id) != nil || isTerminating { return }
        if id == launchWindowID {
            // The unregistered launch window: nothing to hand over.
            launchWindowID = nil
            states[id] = nil
            return
        }
        userClosed(id)
    }

    /// Flushes state and stops saving (quit).
    func prepareForTermination() async {
        recordSaver.geometryTimer.cancel()
        await closeIncognitoWindowsForTermination()
        await recordSaver.flushSaves()
        isTerminating = true
        membershipObservation?.cancel()
        // Chromium stops later, as the last quit step (QuitCompletion).
    }

    /// Quit: each open window's sidebar change still waiting for its idle task reaches the snapshot
    /// store (`SidebarSnapshotRecorder.flushNow`), before the store's flush.
    func flushSidebarSnapshots() async {
        for controller in controllers {
            await controller.sidebar.flushSnapshot()
        }
    }

    /// Copies each open window's frame and display into the registry.
    func captureGeometry() {
        for controller in controllers {
            guard let window = controller.window, !window.styleMask.contains(.fullScreen) else { continue }
            let display = window.screen.flatMap(WindowPlacementFallback.displayID(of:))
            registry.apply { registry in
                registry.setGeometry(controller.state.id, frame: window.frame, display: display)
                return WindowRegistry.Changes()
            }
        }
    }
}
