import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import Observation

/// Opens, restores, and persists windows. The window list, frames, shown
/// workspace, sidebar width, and per-pane tab selection live in the daemon's
/// `personal` frontend projection (architecture.md 1), written 500 ms after
/// the last change and flushed on quit.
final class WindowManager {
    unowned let services: AppServices
    private(set) var controllers: [WindowController] = []
    private weak var lastActive: WindowController?
    private var saveTask: Task<Void, Never>?
    private var loadObservation: Task<Void, Never>?
    private var restored = false
    /// The window opened at launch before the saved state loaded.
    private weak var launchWindow: WindowController?
    /// Windows placed by `TestWindowPlacement` so far (cascade ordinal).
    private var placedWindows = 0
    private(set) var isTerminating = false
    var onFirstWindow: ((WindowController) -> Void)?

    init(services: AppServices) {
        self.services = services
    }

    var active: WindowController? {
        if let key = NSApp.keyWindow, let controller = controllers.first(where: { $0.window === key }) { return controller }
        return lastActive ?? controllers.first
    }

    func didActivate(_ controller: WindowController) { lastActive = controller }

    // MARK: Restore

    /// Opens one window at once (it shows the connecting state until the
    /// daemon answers), then restores the saved windows once the first
    /// snapshot arrives, the launch window becoming the first of them.
    /// Creates a workspace only when the daemon tree is empty.
    func restoreWhenLoaded() {
        if controllers.isEmpty { launchWindow = open(record: nil) }
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
        let store = services.daemon.store
        var document = WindowStateDocument()
        if let windowState = services.daemon.windowState {
            document = (try? await windowState.load()) ?? WindowStateDocument()
        }
        if store.workspaces.isEmpty {
            _ = await createWorkspace()
        }
        let live = Set(store.workspaces.map(\.id))
        // A window on a Cloud machine is kept: its machine connects after
        // sign-in restores, and the window waits for it.
        let records = document.windows.sorted { $0.order > $1.order }.filter { record in
            record.machine != nil || (record.workspaceKey.map { live.contains($0.rawValue) } ?? true)
        }
        var pending = records[...]
        var adopted: WindowController?
        if let launchWindow, controllers.contains(where: { $0 === launchWindow }) {
            // Adopt the last record (the frontmost after the reverse sort),
            // so it stays in front like a freshly opened one would.
            if let record = pending.popLast() {
                let placed = services.environment.testWindow != nil
                let frame = placed ? nil : record.frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
                launchWindow.adopt(record, frame: frame)
                adopted = launchWindow
            }
            self.launchWindow = nil
        }
        for record in pending { open(record: record) }
        // The adopted record was the frontmost; keep it in front.
        if let adopted, !pending.isEmpty { present(adopted) }
        if controllers.isEmpty { open(record: nil) }
    }

    private func present(_ controller: WindowController) {
        if services.environment.testWindow != nil, services.environment.noActivate {
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

    @discardableResult
    func open(record: WindowRecord?, workspaceID: String? = nil) -> WindowController {
        let state = WindowState(id: record?.id ?? UUID().uuidString.lowercased(),
                                workspaceID: workspaceID ?? record?.workspaceKey?.rawValue,
                                machineID: workspaceID.flatMap { services.machines.daemon(forWorkspace: $0)?.machineID } ?? record?.machine)
        for (pane, tab) in record?.selectedTabs ?? [:] { state.selection.select(tab, in: pane) }
        var frame = record?.frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        let placement = services.environment.testWindow
        if let placement, let placed = placement.windowFrame(ordinal: placedWindows, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            frame = placed
            placedWindows += 1
        }
        let controller = WindowController(state: state, services: services, frame: frame)
        controller.sidebar.restore(width: record?.sidebarWidth, collapsed: record?.sidebarCollapsed ?? false)
        controllers.append(controller)
        present(controller)
        if controllers.count == 1 { onFirstWindow?(controller) }
        stateDidChange(state)
        return controller
    }

    // MARK: Workspaces and windows

    func show(workspaceID: String, in state: WindowState) {
        guard state.workspaceID != workspaceID else { return }
        if let machine = services.machines.daemon(forWorkspace: workspaceID)?.machineID { state.machineID = machine }
        state.workspaceID = workspaceID
        stateDidChange(state)
    }

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
        Task {
            guard let id = await createWorkspace(on: daemon) else { return }
            if let state { show(workspaceID: id, in: state) } else { open(record: nil, workspaceID: id) }
        }
    }

    func newWindow() {
        Task {
            guard let id = await createWorkspace() else { return }
            open(record: nil, workspaceID: id)
        }
    }

    func windowWillClose(_ controller: WindowController) {
        controllers.removeAll { $0 === controller }
        controller.teardown()
        guard !isTerminating, let windowState = services.daemon.windowState else { return }
        let id = controller.state.id
        Task { try? await windowState.removeWindow(id: id) }
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

    func saveNow() async {
        guard let windowState = services.daemon.windowState else { return }
        let records = currentRecords()
        // Keys on every machine, plus those of windows whose machine has not
        // loaded yet (they must survive until it reconnects).
        let pendingCloud = records.filter { $0.machine != nil }.compactMap(\.workspaceKey)
        let live = Set(services.machines.allWorkspaces.compactMap(\.0.key) + pendingCloud)
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
        // Close Chromium before exit without spinning the run loop (5a).
        await services.cache.cef.shutdown()
    }

    private func currentRecords() -> [WindowRecord] {
        let ordered = NSApp.orderedWindows
        return controllers.map { controller in
            let state = controller.state
            let frame = controller.window?.frame ?? .zero
            let workspace = state.workspaceID.flatMap { services.machines.workspace(id: $0)?.0 }
            var selected: [String: String] = [:]
            for pane in workspace?.screens.flatMap(\.panes) ?? [] {
                if let tab = state.selection.selection(in: pane.id) { selected[pane.id] = tab }
            }
            let sidebar = controller.sidebar.record
            return WindowRecord(
                id: state.id,
                workspaceKey: workspace?.key ?? state.workspaceID.map { WorkspaceKey(rawValue: $0) },
                machine: state.machineID == MachineRegistry.localID ? nil : state.machineID,
                frame: WindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                isFullScreen: controller.window?.styleMask.contains(.fullScreen) ?? false,
                sidebarWidth: sidebar.width,
                sidebarCollapsed: sidebar.collapsed,
                selectedTabs: selected,
                order: controller.window.flatMap { ordered.firstIndex(of: $0) } ?? controllers.count
            )
        }
    }
}
