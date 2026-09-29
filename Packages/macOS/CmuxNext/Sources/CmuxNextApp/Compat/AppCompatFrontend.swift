import AppKit
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Observation
import Synchronization

/// The App side of the cmux CLI compat layer (`CompatService`): publishes
/// window/focus/selection state for off-main CLI reads, and runs the few
/// CLI requests that change app-local state (show a workspace, focus a
/// pane, select a tab, window open/focus/close, browser page operations).
///
/// Reads never touch the main actor: `snapshot()` and the daemon connection
/// come from lock-protected copies republished on every change.
/// `perform` runs on the main actor and republishes before returning.
@MainActor
final class AppCompatFrontend: CompatFrontend {
    unowned let services: AppServices
    private nonisolated let published = Mutex(CompatFrontendSnapshot())
    private nonisolated let connectionBox = Mutex<DaemonConnection?>(nil)
    private var observation: Task<Void, Never>?
    private var connectionObservation: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        let daemon = services.daemon
        connectionObservation = Task { [weak self] in
            for await connection in Observations({ daemon.connection }) {
                self?.connectionBox.withLock { $0 = connection }
            }
        }
        observation = Task { [weak self] in
            for await snapshot in Observations({ [weak self] in self?.makeSnapshot() ?? CompatFrontendSnapshot() }) {
                self?.published.withLock { $0 = snapshot }
            }
        }
    }

    /// For `CompatService`'s connection provider (off-main).
    nonisolated func currentConnection() -> DaemonConnection? { connectionBox.withLock { $0 } }

    nonisolated func snapshot() -> CompatFrontendSnapshot { published.withLock { $0 } }

    /// Republishes now (window list and key-window changes are not observable).
    func publish() {
        let snapshot = makeSnapshot()
        published.withLock { $0 = snapshot }
    }

    private func makeSnapshot() -> CompatFrontendSnapshot {
        guard let windows = services.windows else { return CompatFrontendSnapshot() }
        let store = services.daemon.store
        let records = windows.controllers.map { controller -> CompatFrontendSnapshot.Window in
            let state = controller.state
            var selected: [String: String] = [:]
            if let workspace = state.workspaceID.flatMap({ id in store.workspaces.first { $0.id == id } }) {
                for pane in workspace.screens.flatMap(\.panes) {
                    if let tab = state.selection.selection(in: pane.id) { selected[pane.id] = tab }
                }
            }
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                if let key = pane.currentTabKey { selected[pane.paneKey] = key }
            }
            let focused = state.workspaceID.flatMap { state.focusedPane[$0]?.rawValue }
            return CompatFrontendSnapshot.Window(
                id: state.id, workspaceID: state.workspaceID, focusedPaneID: focused, selectedTabs: selected,
                isKey: controller.window?.isKeyWindow ?? false, isVisible: controller.window?.isVisible ?? false)
        }
        return CompatFrontendSnapshot(windows: records, activeWindowID: windows.active?.state.id)
    }

    nonisolated func perform(_ intent: CompatFrontendIntent) async throws -> CmuxNextSettings.JSONValue {
        try await performOnMain(intent)
    }

    private func performOnMain(_ intent: CompatFrontendIntent) async throws -> CmuxNextSettings.JSONValue {
        defer { publish() }
        switch intent {
        case .showWorkspace(let workspaceID, let windowID):
            try show(workspaceID: workspaceID, windowID: windowID)
        case .focusPane(let paneID, let workspaceID, let windowID):
            let controller = try show(workspaceID: workspaceID, windowID: windowID)
            focus(paneID: paneID, workspaceID: workspaceID, in: controller)
        case .selectTab(let tabID, let paneID, let workspaceID, let windowID):
            let controller = try show(workspaceID: workspaceID, windowID: windowID)
            controller.state.selection.select(tabID, in: paneID)
            focus(paneID: paneID, workspaceID: workspaceID, in: controller)
            if let pane = controller.content?.panes.values.first(where: { $0.paneKey == paneID }) { pane.select(StripTabID(tabID)) }
            services.windows.stateDidChange(controller.state)
        case .newWindow(let workspaceID):
            let id = workspaceID ?? services.windows.active?.state.workspaceID ?? services.daemon.store.workspaces.first?.id
            let controller = services.windows.open(record: nil, workspaceID: id)
            return ["window_id": .string(controller.state.id)]
        case .focusWindow(let windowID):
            let controller = try window(windowID)
            controller.window?.orderFront(nil)
            controller.window?.makeKey()
            if !services.environment.noActivate { NSApp.activate() }
            services.windows.didActivate(controller)
        case .closeWindow(let windowID):
            try window(windowID).close()
        case .browser(let tabID, let url, let operation):
            return try await AppCompatBrowser.run(operation, tabID: tabID, url: url, services: services)
        }
        return [:]
    }

    private func window(_ id: String) throws -> WindowController {
        guard let controller = services.windows.controllers.first(where: { $0.state.id == id }) else {
            throw ControlError(code: "not_found", message: "Window not found: \(id)")
        }
        return controller
    }

    /// Shows `workspaceID` in the named window, else the active one, else a
    /// new window. Returns the window.
    @discardableResult
    private func show(workspaceID: String, windowID: String?) throws -> WindowController {
        guard services.workspace(id: workspaceID) != nil else {
            throw ControlError(code: "not_found", message: "Workspace not found: \(workspaceID)")
        }
        if let windowID {
            let controller = try window(windowID)
            services.windows.show(workspaceID: workspaceID, in: controller.state)
            return controller
        }
        if let controller = services.windows.active {
            services.windows.show(workspaceID: workspaceID, in: controller.state)
            return controller
        }
        return services.windows.open(record: nil, workspaceID: workspaceID)
    }

    /// Records the focus (applied when the window's content switches to the
    /// workspace) and focuses the pane now when it is already on screen.
    private func focus(paneID: String, workspaceID: String, in controller: WindowController) {
        controller.state.focusedPane[workspaceID] = LayoutPaneID(paneID)
        guard let content = controller.content, content.workspace.id == workspaceID else { return }
        content.layoutModel.focus(LayoutPaneID(paneID))
        content.panes.values.first { $0.paneKey == paneID }?.focusContent()
    }
}
