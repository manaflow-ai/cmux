import AppKit
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
/// 500 ms after the last change and flushed on quit.
final class WindowManager {
    unowned let services: AppServices
    let registry = WindowRegistryStore()
    private(set) var controllers: [WindowController] = []
    /// Per-window state by window id, for every registered window.
    var states: [String: WindowState] = [:]
    private weak var lastActive: WindowController?
    /// Called after a window is ordered in (the restart notice attaches).
    var onPresent: ((WindowController) -> Void)?
    /// Debounced save of window geometry (architecture.md 1: 500 ms).
    private let saveTimer = DemandTimer(owner: "WindowManager.save")
    private var loadObservation: Task<Void, Never>?
    var membershipObservation: Task<Void, Never>?
    /// Records connected sessions in the home session (rooms, data-model.md 1.1).
    private(set) lazy var sessionRegistrar = SessionRegistrar(machines: services.machines)
    /// New workspaces a window asked for before the daemon reported them:
    /// reconcile places each in that window (opening it when it is not
    /// registered yet) and selects it.
    var pendingClaims: [String: String] = [:]
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
    /// The incognito session's off-the-record browser profile while any
    /// incognito window is open (`WindowManager+Incognito`).
    var incognitoSession: BrowserProfileID?
    /// Workspaces of open incognito windows, closed at the next launch when
    /// this run ends without closing them.
    private(set) lazy var incognitoLedger = IncognitoWorkspaceLedger.forApplication(bundleIdentifier: Bundle.main.bundleIdentifier)
    /// Incognito window of each tab it lists (`rememberIncognitoTabs`).
    var incognitoTabHomes: [String: String] = [:]
    /// Clears what the incognito session kept in memory (omnibar history).
    var incognitoHistoryReset: (() -> Void)?

    init(services: AppServices) {
        self.services = services
    }

    var active: WindowController? {
        if let key = NSApp.keyWindow, let controller = owner(of: key) { return controller }
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

    /// Opens one window at once (it shows the connecting state until the
    /// daemon answers; it is not a registry window, since it has no
    /// workspace yet), then restores the saved windows once the first
    /// snapshot arrives, the launch window becoming the frontmost of them.
    /// Creates a workspace only when the daemon tree is empty.
    func restoreWhenLoaded() {
        if controllers.isEmpty {
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
        DebugTimings.markLaunch("daemon_snapshot_loaded")
        var document = WindowStateDocument()
        if let windowState = services.daemon.windowState {
            document = (try? await windowState.load()) ?? WindowStateDocument()
        }
        // Incognito workspaces a crashed run left: closed, never shown.
        let leftover = await incognitoLedger.load()
        if !leftover.isEmpty {
            registry.apply { $0.markDiscarding(leftover); return WindowRegistry.Changes() }
            discard(leftover)
        }
        if services.daemon.store.workspaces.contains(where: { !leftover.contains($0.id) }) == false {
            _ = await createWorkspace()
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
        if registry.value.isIncognito(window.id) {
            controller.sidebar.container.sidebarView.titlebarAccessory = IncognitoBadgeView()
        }
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

    /// The window installed its first workspace content: a window kept off
    /// screen for it is ordered in now.
    func contentDidAppear(_ controller: WindowController) {
        defer { onContentDidAppear?(controller) }
        guard let front = awaitingContent.removeValue(forKey: controller.state.id) else { return }
        present(controller)
        if front { bringToFront(controller) }
    }

    /// Orders a new window in without taking focus under no-activate.
    private func present(_ controller: WindowController) {
        // Tests: never on the user's display. Otherwise one rule: under
        // no-activate behind the others (in front on a test screen), never key.
        if ordersWindowsIn, let window = controller.window { WindowActivation.show(window, .present) }
        onPresent?(controller)
    }

    /// Brings a window forward (not key and no activation under
    /// `CMUX_NEXT_NO_ACTIVATE=1`).
    func bringToFront(_ controller: WindowController) {
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

    // MARK: Persistence

    func stateDidChange(_ state: WindowState) {
        guard restored, !isTerminating else { return }
        saveTimer.schedule(after: .milliseconds(500)) { @MainActor [weak self] in await self?.saveNow() }
    }

    func scheduleSave() {
        guard let any = states.values.first else { return }
        stateDidChange(any)
    }

    func saveNow() async {
        guard let windowState = services.daemon.windowState else { return }
        captureGeometry()
        let records = currentRecords()
        // Keys on every machine, plus those whose machine has not loaded yet
        // (they must survive until it reconnects).
        let live = Set(services.machines.allWorkspaces.compactMap(\.0.key))
            .union(records.flatMap(\.workspaceKeys).filter { !isDead($0.rawValue) })
        do {
            try await windowState.update { document in
                document.windows = records
                document.prune(liveWorkspaces: live)
            }
        } catch {
            services.daemon.logger.error("window state save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Flushes state and stops saving (quit).
    func prepareForTermination() async {
        saveTimer.cancel()
        await closeIncognitoWindowsForTermination()
        await saveNow()
        isTerminating = true
        membershipObservation?.cancel()
        // Close Chromium before exit without spinning the run loop (5a).
        await services.cache.cef.shutdown()
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

    private func currentRecords() -> [WindowRecord] {
        let ordered = NSApp.orderedWindows
        let value = registry.value
        return value.windows.compactMap { window in
            let controller = controller(for: window.id)
            let order = controller?.window.flatMap { ordered.firstIndex(of: $0) }
                ?? (value.recency.firstIndex(of: window.id) ?? 0) + ordered.count
            return value.record(window.id, state: states[window.id], order: order,
                                isFullScreen: controller?.window?.styleMask.contains(.fullScreen) ?? false,
                                selectedTabs: selectedTabs(window: window))
        }
    }

    /// Remembered tab per pane across the window's workspaces.
    private func selectedTabs(window: WindowRegistry.Window) -> [String: String] {
        guard let state = states[window.id] else { return [:] }
        var selected: [String: String] = [:]
        for id in window.workspaceIDs {
            for pane in services.workspace(id: id)?.screens.flatMap(\.panes) ?? [] {
                if let tab = state.selection.selection(in: pane.id) { selected[pane.id] = tab }
            }
        }
        return selected
    }
}
