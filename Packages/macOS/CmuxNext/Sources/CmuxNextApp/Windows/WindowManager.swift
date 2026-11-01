import CmuxNextHibernation
import AppKit
import CmuxNextActions
import CmuxNextAppCore
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextLayout
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
    private(set) var controllers: [WindowController] = [] { didSet { services.background.windowsDidChange() } } // none left: background mode (cx-ghagp)
    /// Per-window state by window id, for every registered window.
    var states: [String: WindowState] = [:]
    private weak var lastActive: WindowController?
    /// The cmux window the event in dispatch came from (`dispatching(eventFrom:_:)`).
    var eventOrigin: EventOrigin?
    /// Called after a window is ordered in (the restart notice attaches).
    var onPresent: ((WindowController) -> Void)?
    /// Writes the window records (WindowRecordSaver).
    lazy var recordSaver = WindowRecordSaver(manager: self)
    private var loadObservation: Task<Void, Never>?
    var membershipObservation: Task<Void, Never>?
    /// Records connected sessions in the home session (rooms, data-model.md 1.1).
    /// A refused record shows once as a toast on the front window (the machine is not saved for restore).
    private(set) lazy var sessionRegistrar = SessionRegistrar(machines: services.machines, notice: { [weak self] session, message in
        guard let window = self?.active?.window ?? NSApp.mainWindow else { return false }
        // Until closed or taken back: it is the person's only sign that this machine will not be restored.
        let older = self?.notSavedToasts[session]
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: "session-registration.not-saved.\(session)", message: message,
                                                           duration: CmuxToast.untilClosed), in: window)
        self?.notSavedToasts[session] = handle
        // A toast with the same id replaces the older one only in the same window.
        if older !== handle { older?.dismiss() }
        return true
    }, withdraw: { [weak self] session in
        self?.notSavedToasts.removeValue(forKey: session)?.dismiss()
    })
    /// The "not saved for restore" toast shown for each session, so it can be taken back.
    private var notSavedToasts: [String: CmuxToastHandle] = [:]
    /// New workspaces a window asked for before the daemon reported them:
    /// reconcile places each in that window (opening it when it is not
    /// registered yet) and selects it.
    var pendingClaims: [String: String] = [:]
    /// Pending claims not to show on arrival; windows to open behind (automation, Option).
    var quietClaims: Set<String> = [], behindWindows: Set<String> = []
    /// Pending claims from runs without view-change permission (an agent's or the CLI's create): they
    /// never open a Cloud machine nobody opened here (#28609); reconcile drops them for its workspaces.
    var backgroundClaims: Set<String> = []
    /// While ``fileOpenedMachine(of:into:)`` re-runs reconcile: a window that pass opens files nothing again.
    var fillingOpenedMachine = false
    /// Restored windows but the front one, not shown yet (`present`); `keepsOrder` while one shows alone.
    private var restacking: Set<String> = [], keepsOrder = false
    /// Frames for windows that open once their claimed workspace arrives.
    var pendingFrames: [String: CGRect] = [:]
    /// Sidebar slots for new workspaces, applied once the daemon reports
    /// them (`applyPendingPlacements`).
    var pendingPlacements: [String: PendingPlacement] = [:]
    /// Registration order survives a daemon snapshot that reports several creates together.
    var pendingPlacementOrder: [String] = []
    /// Retries the placements whose wait for the window's current row ran out (`applyPendingPlacements`).
    let anchorRetry = DemandTimer(owner: "WindowManager.anchorRetry")
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
    /// What `isDead` reads of the Cloud's sign-in and machine list: `CloudService.listFacts`; a test
    /// gives its own account state, which it cannot sign in to reach.
    var cloudList: (CloudService) -> CloudMachineListFacts = \.listFacts
    /// Windows being closed by the registry (not by the user).
    var programmaticCloses: Set<String> = []
    private(set) var restored = false
    /// The saved windows' read failed for good: no restore places the launch window's claims (``awaitsRestore(_:)``).
    private(set) var restoreGaveUp = false
    /// Windows the person closed before `restore` finished (cx-ghagp): the restore puts back the
    /// saved registry, where they are open, and must not open them again. Empty once it finished.
    var closedDuringRestore: Set<String> = []
    /// True while `restore` runs.
    private(set) var restoring = false
    /// The saved window records are not installed (yet, or the launch's read failed: `SavedWindowsRead`):
    /// they may hold windows this launch does not show, so nothing writes them (#26681). True until
    /// the launch's records are installed, so neither a window opened while it waits nor a quit before the
    /// restore started (its flush would write no windows) can replace them.
    private(set) var savedWindowsUnread = true
    /// The launch window the person closed before `restore` finished: the restore registers the
    /// workspaces it would have shown under this id, which is in `closedDuringRestore`, so they
    /// stay in a closed window. Nil once it finished.
    var closedLaunchWindowID: String?
    /// The windows the previous launch left open, captured at restore (Restore Previous App
    /// Launch reopens those closed since); nil before restore and when nothing was saved.
    var previousLaunch: PreviousLaunch?
    /// The window opened at launch before the saved state loaded: it shows the connecting state
    /// outside the registry, then becomes the frontmost restored window (or the window of the
    /// first workspaces). Nil once it is registered.
    var launchWindowID: String?
    /// Windows placed by `TestWindowPlacement` so far (cascade ordinal).
    private var placedWindows = 0
    private(set) var isTerminating = false
    /// False in tests: windows are created but never ordered on screen.
    var ordersWindowsIn = true
    /// Restore finished: windows saved in full screen may enter it.
    var fullScreenRestoreReady = false
    /// A restored window is entering full screen (one at a time).
    var fullScreenRestoreRunning = false
    var onFirstWindow: ((WindowController) -> Void)?
    /// A window installed workspace content (links opened at launch wait for it).
    var onContentDidAppear: ((WindowController) -> Void)?
    /// One-shot work for a workspace a reveal is still mounting, by window
    /// id; dropped when the window shows another workspace or closes.
    private var contentWaiters: [String: [(workspaceID: String, body: () -> Void)]] = [:]
    /// The incognito session's off-the-record browser profile while any
    /// incognito window is open (`WindowManager+Incognito`).
    var incognitoSession: BrowserProfileID?
    /// The incognito space each incognito window shows (window id to space), deleted with its window.
    var incognitoSpaces: [String: ProfileID] = [:]
    /// Workspaces of open incognito windows, closed at the next launch when
    /// this run ends without closing them.
    lazy var incognitoLedger = IncognitoWorkspaceLedger.forApplication(bundleIdentifier: Bundle.main.bundleIdentifier)
    /// Incognito windows waiting for the ephemeral workspace created for
    /// them (`WindowManager+Ephemeral`).
    var pendingEphemeralWindows: [String] = []
    /// Incognito window of each tab it lists (`rememberIncognitoTabs`).
    var incognitoTabHomes: [String: String] = [:]
    /// Clears what the incognito session kept in memory (omnibar history).
    var incognitoHistoryReset: (() -> Void)?

    init(services: AppServices) {
        self.services = services
        WindowActivation.didOrder = { [weak self] window, inFront in self?.windowDidOrder(window, inFront: inFront) }
    }

    /// The registry's recency (the window order, saved as `WindowRecord.order`) follows each order and key change.
    func windowDidOrder(_ window: NSWindow, inFront: Bool) {
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
        // A "not saved for restore" notice that came while no window could show it shows now.
        sessionRegistrar.showPendingNotices()
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

    func controller(for windowID: String) -> WindowController? {
        controllers.first { $0.state.id == windowID }
    }

    /// The window's state, created on first use.
    func state(for windowID: String) -> WindowState {
        if let state = states[windowID] { return state }
        let state = WindowState(id: windowID)
        states[windowID] = state
        return state
    }

    // MARK: Restore

    /// Opens one window at once (from the launch snapshot, else in the
    /// connecting state, outside the registry), then restores the saved
    /// windows once the first live snapshot arrives, the launch window
    /// becoming the frontmost. Creates a workspace only for an empty tree.
    func restoreWhenLoaded() {
        registry.isLaunching = !restored
        if controllers.isEmpty, !LaunchSnapshotWindow(manager: self).show() {
            let id = UUID().uuidString.lowercased()
            launchWindowID = id
            makeController(for: WindowRegistry.Window(id: id, frame: services.daemon.launchSnapshotWindows?.lastFrame?.rect,
                                                      display: services.daemon.launchSnapshotWindows?.lastDisplay))
        }
        let store = services.daemon.store
        loadObservation = Task { [weak self] in
            for await loaded in ObservationStream({ store.isLoaded }) where loaded {
                await self?.restore()
                return
            }
        }
    }

    private func restore() async {
        guard !restored, !restoring else { return }
        restoring = true
        defer {
            restoring = false
            closedDuringRestore = []
            closedLaunchWindowID = nil
        }
        registry.provisional = [:]
        DebugTimings.markLaunch("daemon_snapshot_loaded")
        let saved = await readSavedWindows()
        guard !Task.isCancelled, !isTerminating else { return }
        guard let document = saved else { restoreGaveUp = true; return reconcileMembership() }
        // Incognito workspaces a crashed run left on a daemon without state
        // resources: the app's ledger owns them, so they close, never shown.
        // A daemon with state resources owns its ephemeral workspaces (it closes them at its
        // next start); until then they show in an incognito window only, so wait for its flags.
        // Incognito spaces a crashed run left: deleted, never shown.
        if let home = services.machines.local.connection {
            for space in await incognitoLedger.loadSpaces() { _ = try? await home.deleteProfile(ProfileID(rawValue: space), moveTo: nil) }
        }
        let leftover = await incognitoLedger.load()
        IncognitoLeftovers.discard(leftover, self)
        await EphemeralWorkspaces.awaitFlags(self)
        let firstWorkspace = await FirstWorkspaceLaunch(manager: self).create(leftover: leftover)
        guard !Task.isCancelled, !isTerminating else { return }
        restored = true
        let restoredRegistry = WindowRegistry(records: document.windows)
        if !restoredRegistry.windows.isEmpty {
            previousLaunch = PreviousLaunch(windowIDs: restoredRegistry.recency.filter { restoredRegistry.window($0)?.isOpen == true },
                                            restoredAtMs: UInt64(max(0, Date().timeIntervalSince1970 * 1000)))
        }
        let adopted = adoptLaunchWindow(restoredRegistry, records: document.windows)
        if adopted == nil { placeLaunchWindow(document) }
        // The closed launch window stood for the saved window it would have become.
        if closedLaunchWindowID != nil, let front = adoptableFront(restoredRegistry) { closedDuringRestore.insert(front) }
        for record in document.windows where states[record.id] == nil { states[record.id] = WindowState(record: record) }
        rememberMachines(of: document)
        if !restoredRegistry.windows.isEmpty {
            registry.apply { registry in
                registry = restoredRegistry
                keepClosedDuringRestore(&registry)
                return WindowRegistry.Changes()
            }
        }
        reconcileMembership()
        // Every remaining window closed (the open ones lost their workspaces while the app was
        // not running): the most recent one opens, so the app never starts with no window.
        if closedDuringRestore.isEmpty, !registry.value.windows.isEmpty, !registry.value.windows.contains(where: \.isOpen),
           let front = registry.value.recency.first {
            registry.apply { $0.setRestored(front, open: true); return WindowRegistry.Changes() }
        }
        // Restored windows but the front one come back at their saved place, in any content arrival order.
        restacking = Set(registry.value.recency.filter { registry.value.window($0)?.isOpen == true }.dropFirst())
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
        // The adopted window is the frontmost saved one; keep it in front. It was presented at
        // launch already: raise it, never present it again, which under no-activate orders a
        // window behind the others and would save it last in the window order.
        if let adopted, controllers.count > 1, ordersWindowsIn, let window = adopted.window { WindowActivation.show(window, .raise) }
        observeMembership()
        sessionRegistrar.start()
        registry.isLaunching = false
        fullScreenRestoreReady = true
        enterRestoredFullScreens()
        // Its New Tab page or Home; not after the person closed a window meanwhile: revealing it
        // opens a window again (the Home workspace shows before the restore finished).
        if closedDuringRestore.isEmpty { FirstWorkspaceLaunch(manager: self).land(firstWorkspace, leftover: leftover) }
        // Classic cmux's session comes over once, after restore so the restored
        // registry never overwrites where its workspaces land.
        let onboarding = AppOnboardingServices(owner: services.onboarding)
        Task { await onboarding.migrateClassicAtLaunch(firstWorkspace: firstWorkspace) }
        savedWindowsUnread = false
        recordSaver.scheduleSave()
    }

    /// The saved window records, kept pending through timeouts and reconnects. A cancelled or
    /// permanent failure returns nil, never an empty saved session. Saves stay blocked until
    /// restore installs the returned records. Each attempt uses the current connection's store.
    func readSavedWindows(_ read: SavedWindowsRead = SavedWindowsRead(),
                          load: ((Duration) async throws -> WindowStateDocument)? = nil) async -> WindowStateDocument? {
        savedWindowsUnread = true
        let daemon = services.daemon
        let load = load ?? { deadline in
            guard let windowState = daemon.windowState else { throw DaemonError.notConnected }
            return try await windowState.load(timeout: deadline)
        }
        switch await read.run(waitUntilReady: { try await daemon.waitForReadySnapshot() }, load) {
        case .loaded(let saved):
            return saved
        case .unread(let error):
            daemon.logger.error("saved windows unread, kept unwritten: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The launch window takes the frontmost saved window's identity and
    /// state, so relaunch shows it without opening a second window. With
    /// nothing saved it stays the only window and receives every workspace.
    private func adoptLaunchWindow(_ restored: WindowRegistry, records: [WindowRecord]) -> WindowController? {
        guard let launchID = launchWindowID, let launch = controller(for: launchID),
              let front = adoptableFront(restored),
              let record = records.first(where: { $0.id == front }) else { return nil }
        launch.state.adopt(record)
        launchWindowID = front
        launchWindowAdopted(from: launchID, as: front)
        states[launchID] = nil
        states[front] = launch.state
        launch.sidebar.restore(width: record.sidebarWidth, hidden: record.sidebarHidden)
        if services.environment.testWindow == nil, let frame = restored.window(front)?.frame {
            launch.window?.setFrame(WindowPlacementFallback.visible(frame, display: restored.window(front)?.display), display: true)
        }
        return launch
    }

    /// No saved window can show now (their workspaces ended, or the last window closed): the
    /// launch window opens where the front window last was (#25568).
    private func placeLaunchWindow(_ document: WindowStateDocument) {
        guard services.environment.testWindow == nil, let launch = launchWindowID.flatMap(controller(for:)),
              let frame = document.lastFrame?.rect else { return }
        launch.window?.setFrame(WindowPlacementFallback.visible(frame, display: document.lastDisplay), display: true)
    }

    /// A window the person closed before the restore finished stays closed, even the last one: no
    /// window open is the background mode, not a launch to recover. Applied in the registry step
    /// itself, so no sync ever opens (and presents) it in between.
    func keepClosedDuringRestore(_ registry: inout WindowRegistry) {
        for id in closedDuringRestore where registry.window(id)?.isOpen == true { registry.setRestored(id, open: false) }
    }

    /// The frontmost saved window that can show a workspace now; one whose
    /// workspaces are gone or still connecting would leave the launch
    /// window on screen with nothing to show.
    private func adoptableFront(_ restored: WindowRegistry) -> String? {
        restored.recency.first { id in restored.window(id).map { $0.isOpen && hasMirroredWorkspace($0) } == true }
    }

    // MARK: Controllers

    /// Creates the controller of registered window `id`.
    @discardableResult
    func makeController(for window: WindowRegistry.Window) -> WindowController {
        let state = state(for: window.id)
        var frame = (window.frame ?? pendingFrames.removeValue(forKey: window.id)).map { WindowPlacementFallback.visible($0, display: window.display) }
        let placement = services.environment.testWindow
        if let placement, let placed = placement.windowFrame(ordinal: placedWindows, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            frame = placed
            placedWindows += 1
        }
        let controller = WindowController(state: state, services: services, frame: frame)
        controller.sidebar.restore(width: state.sidebarWidth, hidden: state.sidebarHidden)
        if registry.value.isIncognito(window.id) { controller.showIncognitoBadge() }
        services.dragSession.installWorkspaceHandoff(on: controller)
        controllers.append(controller)
        // Its content goes in before it is ordered in (the launch snapshot's workspace, else the
        // connecting state), so its first frame on screen draws it, never the backdrop alone; the
        // controller's own observer would install it a main-actor hop later.
        controller.showWorkspace(requested: state.workspaceID)
        // A window none of whose workspaces is mirrored yet stays off screen
        // until `contentDidAppear` (never an empty frame). The launch window
        // (no workspaces) shows the connecting state at once.
        if controller.content != nil || hasMirroredWorkspace(window) || window.workspaceIDs.isEmpty {
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
        controller.teardown()
        if programmaticCloses.remove(id) != nil || isTerminating { return }
        if id == launchWindowID {
            // The unregistered launch window: nothing to hand over. It often wears the saved front
            // window's id, so the restore must not open that one again either.
            if restoring || !restored {
                closedDuringRestore.insert(id)
                closedLaunchWindowID = id
            }
            launchWindowID = nil
            states[id] = nil
            return
        }
        userClosed(id)
    }

    /// Flushes state and stops saving (quit). The records go first: they
    /// never hold an incognito window, and a slow daemon close of an
    /// incognito workspace must not keep them past the quit step's limit.
    func prepareForTermination() async {
        loadObservation?.cancel()
        recordSaver.geometryTimer.cancel()
        await recordSaver.flushSaves()
        await closeIncognitoWindowsForTermination()
        await recordSaver.flushSaves()
        stopSavingForTermination()
        // Chromium stops later, as the last quit step (QuitSteps).
    }

    /// Stops saving for the quit at once: also when ``prepareForTermination()``
    /// passed its quit-step limit and still runs (`QuitSaveSteps`).
    func stopSavingForTermination() {
        recordSaver.geometryTimer.cancel()
        isTerminating = true
        membershipObservation?.cancel()
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

    // MARK: Workspace hibernation (plans/cmux-next/workspace-hibernation-DESIGN.md)

    /// Workspaces some window keeps mounted off screen.
    var parkedWorkspaceIDs: Set<String> { Set(controllers.flatMap(\.parked.keys)) }

    /// Workspaces shown in a window: its content, the one under a top page, and `sidebar.multiView` companions.
    var shownWorkspaceIDs: Set<String> {
        controllers.reduce(into: Set<String>()) { shown, window in
            if let id = window.content?.workspace.id { shown.insert(id) }
            if let id = window.state.workspaceID { shown.insert(id) }
            shown.formUnion(window.state.viewSet?.ids ?? [])
            if LayoutTunables.dockedWorkspaces.value {
                shown.formUnion(window.state.docks.visible.map(\.workspace))
                if let stage = window.state.stageWorkspaceID { shown.insert(stage) }
            }
        }
    }

    /// Every workspace this app holds memory for (mounted in a window, or a tab `holdsMemory` says
    /// holds a surface or page), with what keeps it awake.
    func hibernationResidents(in stores: [DaemonStore], holdsMemory: (String) -> Bool) -> [WorkspaceHibernationResident] {
        let mounted = parkedWorkspaceIDs, hidden = hiddenSpaceTest()
        return WorkspaceActivityFacts.all(in: stores) { workspace, tabs in mounted.contains(workspace.id) || tabs.contains { holdsMemory($0.id) } }
            .map { WorkspaceHibernationResident(workspace: $0.workspace, lastActivity: $0.lastActivity, pinned: $0.pinned,
                                                running: $0.running, needsAttention: $0.needsAttention, inHiddenSpace: hidden($0.workspace)) }
    }

    /// Workspace `id` hibernated: every window unmounts its parked content.
    func releaseParked(_ id: String) {
        for window in controllers { window.releaseParked(id) }
    }
}
