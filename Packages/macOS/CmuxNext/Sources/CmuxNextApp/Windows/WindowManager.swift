import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import Observation

/// Opens, restores, closes, and persists windows.
///
/// Two kinds of state, two owners (user requirement 2026-09-29):
/// - `registry` (app-wide): which workspaces each window lists and which
///   windows exist. Transitions are in `WindowManager+Membership`.
/// - `WindowState` (one per window, in `states`): everything else the
///   window owns. Outlives its controller while the window is registered.
///
/// Controllers follow the registry declaratively (`sync`). Both persist in
/// the daemon's `personal` frontend projection (architecture.md 1), written
/// 500 ms after the last change and flushed on quit.
final class WindowManager {
    unowned let services: AppServices
    let registry = WindowRegistryStore()
    private(set) var controllers: [WindowController] = []
    /// Per-window state by window id, for every registered window.
    var states: [String: WindowState] = [:]
    private weak var lastActive: WindowController?
    private var saveTask: Task<Void, Never>?
    private var loadObservation: Task<Void, Never>?
    var membershipObservation: Task<Void, Never>?
    /// New workspaces a window asked for before the daemon reported them:
    /// reconcile places each in that window and selects it.
    var pendingClaims: [String: String] = [:]
    /// Machine each workspace was last seen on, to tell "gone" from "its
    /// machine is still connecting".
    var seenMachine: [String: String] = [:]
    /// Windows being closed by the registry (not by the user).
    var programmaticCloses: Set<String> = []
    private(set) var restored = false
    /// The window opened at launch, before the saved state loaded; it
    /// becomes the frontmost restored window.
    private var launchWindowID: String?
    /// Windows placed by `TestWindowPlacement` so far (cascade ordinal).
    private var placedWindows = 0
    private(set) var isTerminating = false
    /// False in tests: windows are created but never ordered on screen.
    var ordersWindowsIn = true
    var onFirstWindow: ((WindowController) -> Void)?

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
    /// daemon answers), then restores the saved windows once the first
    /// snapshot arrives, the launch window becoming the frontmost of them.
    /// Creates a workspace only when the daemon tree is empty.
    func restoreWhenLoaded() {
        if controllers.isEmpty {
            let id = UUID().uuidString.lowercased()
            launchWindowID = id
            transition { $0.openWindow(id: id) }
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
        var document = WindowStateDocument()
        if let windowState = services.daemon.windowState {
            document = (try? await windowState.load()) ?? WindowStateDocument()
        }
        if services.daemon.store.workspaces.isEmpty {
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
        // The adopted window is the frontmost saved one; keep it in front.
        if let adopted, controllers.count > 1 { present(adopted) }
        observeMembership()
    }

    /// The launch window takes the frontmost saved window's identity and
    /// state, so relaunch shows it without opening a second window. With
    /// nothing saved it stays the only window and receives every workspace.
    private func adoptLaunchWindow(_ restored: WindowRegistry, records: [WindowRecord]) -> WindowController? {
        guard let launchID = launchWindowID else { return nil }
        launchWindowID = nil
        guard let launch = controller(for: launchID), let front = restored.recency.first,
              let record = records.first(where: { $0.id == front }) else { return nil }
        launch.state.adopt(record)
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
        var frame = window.frame.map { WindowPlacementFallback.visible($0, display: window.display) }
        let placement = services.environment.testWindow
        if let placement, let placed = placement.windowFrame(ordinal: placedWindows, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            frame = placed
            placedWindows += 1
        }
        let controller = WindowController(state: state, services: services, frame: frame)
        controller.sidebar.restore(width: state.sidebarWidth, hidden: state.sidebarHidden)
        services.dragSession.installWorkspaceHandoff(on: controller)
        controllers.append(controller)
        present(controller)
        if controllers.count == 1 { onFirstWindow?(controller) }
        return controller
    }

    /// Orders a new window in without taking focus under no-activate.
    private func present(_ controller: WindowController) {
        if !ordersWindowsIn {
            // Tests: never on the user's display.
        } else if services.environment.testWindow != nil, services.environment.noActivate {
            // Agent screenshot launch: in front on its own screen, still not
            // key and the app not activated.
            controller.window?.orderFrontRegardless()
        } else if services.environment.noActivate {
            // Behind every other window, not key, app not activated.
            controller.window?.orderBack(nil)
        } else {
            controller.showWindow(nil)
        }
    }

    /// Brings a window forward (not key and no activation under
    /// `CMUX_NEXT_NO_ACTIVATE=1`).
    func bringToFront(_ controller: WindowController) {
        guard ordersWindowsIn, let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if services.environment.noActivate {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ controller: WindowController) {
        let id = controller.state.id
        controllers.removeAll { $0 === controller }
        controller.teardown()
        if programmaticCloses.remove(id) != nil || isTerminating { return }
        userClosed(id)
    }

    // MARK: Workspaces

    /// Creates a workspace with one terminal on `daemon` (default: the local
    /// daemon). Returns its id.
    func createWorkspace(cwd: String? = nil, on daemon: DaemonService? = nil) async -> String? {
        let daemon = daemon ?? services.daemon
        do {
            return try await createWorkspace(WorkspaceSpawn(cwd: cwd), on: daemon)
        } catch {
            daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func newWorkspace(in state: WindowState?, on daemon: DaemonService? = nil) {
        let windowID = state?.id
        Task {
            guard let id = await createWorkspace(on: daemon) else { return }
            if let windowID, let state = states[windowID], registry.value.window(windowID)?.isOpen == true {
                claim(workspaceID: id, in: state)
            } else {
                openWindow(workspaces: [id])
            }
        }
    }

    /// New window with a new workspace. Returns the window id right away;
    /// the window opens once the workspace exists.
    @discardableResult
    func newWindow(frame: CGRect? = nil) -> String {
        let windowID = UUID().uuidString.lowercased()
        Task {
            guard let id = await createWorkspace() else { return }
            openWindow(id: windowID, workspaces: [id], frame: frame)
        }
        return windowID
    }

    // MARK: Persistence

    func stateDidChange(_ state: WindowState) {
        guard restored, !isTerminating else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(for: .milliseconds(500)) } catch { return }
            await self?.saveNow()
        }
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
        saveTask?.cancel()
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
