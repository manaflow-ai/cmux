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

    /// Opens the saved windows once the first snapshot arrives. Creates a
    /// workspace only when the daemon tree is empty.
    func restoreWhenLoaded() {
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
        let records = document.windows.sorted { $0.order > $1.order }.filter { record in
            record.workspaceKey.map { live.contains($0.rawValue) } ?? true
        }
        for record in records { open(record: record) }
        if controllers.isEmpty { open(record: nil) }
    }

    @discardableResult
    func open(record: WindowRecord?, workspaceID: String? = nil) -> WindowController {
        let state = WindowState(id: record?.id ?? UUID().uuidString.lowercased(),
                                workspaceID: workspaceID ?? record?.workspaceKey?.rawValue)
        for (pane, tab) in record?.selectedTabs ?? [:] { state.selection.select(tab, in: pane) }
        let frame = record?.frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        let controller = WindowController(state: state, services: services, frame: frame)
        controller.sidebar.restore(width: record?.sidebarWidth, collapsed: record?.sidebarCollapsed ?? false)
        controllers.append(controller)
        if services.environment.noActivate {
            controller.window?.orderFront(nil)
        } else {
            controller.showWindow(nil)
        }
        if controllers.count == 1 { onFirstWindow?(controller) }
        stateDidChange(state)
        return controller
    }

    // MARK: Workspaces and windows

    func show(workspaceID: String, in state: WindowState) {
        guard state.workspaceID != workspaceID else { return }
        state.workspaceID = workspaceID
        stateDidChange(state)
    }

    /// Creates a workspace with one terminal. Returns its id.
    func createWorkspace(cwd: String? = nil) async -> String? {
        guard let connection = services.daemon.connection else { return nil }
        do {
            let result = try await connection.createWorkspace()
            _ = try await connection.createTerminal(in: result.key, cwd: cwd ?? NSHomeDirectory())
            return result.key.rawValue
        } catch {
            services.daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func newWorkspace(in state: WindowState?) {
        Task {
            guard let id = await createWorkspace() else { return }
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
        let live = Set(services.daemon.store.workspaces.compactMap(\.key))
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
            let workspace = services.daemon.store.workspaces.first { $0.id == state.workspaceID }
            var selected: [String: String] = [:]
            for pane in workspace?.screens.flatMap(\.panes) ?? [] {
                if let tab = state.selection.selection(in: pane.id) { selected[pane.id] = tab }
            }
            let sidebar = controller.sidebar.record
            return WindowRecord(
                id: state.id,
                workspaceKey: workspace?.key,
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
