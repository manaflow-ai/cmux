import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextDaemon
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
    private(set) var controllers: [WindowController] = []
    /// Per-window state by window id, for every registered window.
    var states: [String: WindowState] = [:]
    private weak var lastActive: WindowController?
    /// Called after a window is ordered in (the restart notice attaches).
    var onPresent: ((WindowController) -> Void)?
    /// Writes the window records (WindowRecordSaver).
    lazy var recordSaver = WindowRecordSaver(manager: self)
    private var loadObservation: Task<Void, Never>?
    var membershipObservation: Task<Void, Never>?
    /// Records connected sessions in the home session (rooms, data-model.md 1.1).
    private(set) lazy var sessionRegistrar = SessionRegistrar(machines: services.machines)
    /// New workspaces a window asked for before the daemon reported them:
    /// reconcile places each in that window (opening it when it is not
    /// registered yet) and selects it.
    var pendingClaims: [String: String] = [:]
    /// Pending claims not to show on arrival; windows to open behind (automation, Option).
    var quietClaims: Set<String> = [], behindWindows: Set<String> = []
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
    /// The window opened at launch, before the saved state loaded: it shows
    /// the connecting state outside the registry, then becomes the frontmost
    /// restored window (or the window of the first workspaces). Nil once it
    /// is registered.
    var launchWindowID: String?
    /// Windows placed by `TestWindowPlacement` so far (cascade ordinal).
    private var placedWindows = 0
    private(set) var isTerminating = false
    /// False in tests: windows are created but never ordered on screen.
    var ordersWindowsIn = true
    var onFirstWindow: ((WindowController) -> Void)?
    /// A window installed workspace content (links opened at launch wait for it).
    var onContentDidAppear: ((WindowController) -> Void)?
    /// One-shot work for a workspace a reveal is still mounting, by window
    /// id; dropped when the window shows another workspace or closes.
    private var contentWaiters: [String: [(workspaceID: String, body: () -> Void)]] = [:]
    /// The incognito session's off-the-record browser profile while any
    /// incognito window is open (`WindowManager+Incognito`).
    var incognitoSession: BrowserProfileID?
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
    }

    var active: WindowController? {
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
        registry.apply { registry in
            registry.activate(controller.state.id)
            return WindowRegistry.Changes()
        }
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
            makeController(for: WindowRegistry.Window(id: id))
        }
        let store = services.daemon.store
        loadObservation = Task { [weak self] in
            for await loaded in Observations({ store.isLoaded }) where loaded {
                await self?.restore()
                return
            }
        }
    }

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
        // A daemon with state resources owns its ephemeral workspaces (it
        // closes them at its next start); until then they show in an
        // incognito window, never a normal one, so wait for its flags.
        let leftover = await incognitoLedger.load()
        if !leftover.isEmpty {
            registry.apply { $0.markDiscarding(leftover); return WindowRegistry.Changes() }
            discard(leftover)
        }
        await EphemeralWorkspaces.awaitFlags(self)
        if FirstWorkspace.isNeeded(services.daemon.store.workspaces, leftover: leftover) {
            _ = await createWorkspace(newTabPage: true)
        }
        let restoredRegistry = WindowRegistry(records: document.windows)
        let adopted = adoptLaunchWindow(restoredRegistry, records: document.windows)
        for record in document.windows where states[record.id] == nil { states[record.id] = WindowState(record: record) }
        if !restoredRegistry.windows.isEmpty {
            registry.apply { registry in
                registry = restoredRegistry
                return WindowRegistry.Changes()
            }
        }
        reconcileMembership()
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
    }

    /// The launch window takes the frontmost saved window's identity and
    /// state, so relaunch shows it without opening a second window. With
    /// nothing saved it stays the only window and receives every workspace.
    private func adoptLaunchWindow(_ restored: WindowRegistry, records: [WindowRecord]) -> WindowController? {
        // The frontmost saved window that can show a workspace now; one whose
        // workspaces are gone or still connecting would leave the launch
        // window on screen with nothing to show.
        guard let launchID = launchWindowID, let launch = controller(for: launchID),
              let front = restored.recency.first(where: { id in restored.window(id).map(hasMirroredWorkspace) == true }),
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
        // A window none of whose workspaces is mirrored yet stays off screen
        // until `contentDidAppear` (never an empty frame). The launch window
        // (no workspaces) shows the connecting state at once.
        if hasMirroredWorkspace(window) || window.workspaceIDs.isEmpty {
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
        if ordersWindowsIn, let window = controller.window { WindowActivation.show(window, behind ? .presentBehind : .present) }
        onPresent?(controller)
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
        awaitingContent[id] = nil
        contentWaiters[id] = nil
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
