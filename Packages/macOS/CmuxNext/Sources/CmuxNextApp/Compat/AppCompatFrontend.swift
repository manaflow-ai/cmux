import AppKit
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Observation
import Synchronization

/// The App side of the cmux CLI compat layer (`CompatService`): runs the
/// CLI requests that change app-local state (show a workspace, focus a
/// pane, select a tab, window open/focus/close) and browser page
/// operations. CLI reads never come here; they answer from the published
/// `ControlSnapshot`.
///
/// `perform` runs on the main actor through the router's bounded work
/// queue and is short and synchronous. The daemon connection is mirrored
/// into a lock so `CompatService` reads it off the main actor.
@MainActor
final class AppCompatFrontend: CompatFrontend {
    unowned let services: AppServices
    private nonisolated let connectionBox = Mutex<DaemonConnection?>(nil)
    private var connectionObservation: Task<Void, Never>?
    /// Runs after every intent: the App publishes the control snapshot so
    /// the next CLI read sees the change.
    var afterIntent: (() -> Void)?

    init(services: AppServices) {
        self.services = services
        let daemon = services.daemon
        connectionObservation = Task { [weak self] in
            for await connection in Observations({ daemon.connection }) {
                self?.connectionBox.withLock { $0 = connection }
            }
        }
    }

    /// For `CompatService`'s connection provider (off-main).
    nonisolated func currentConnection() -> DaemonConnection? { connectionBox.withLock { $0 } }

    nonisolated func browser(tabID: String, url: String?, operation: CompatBrowserOperation) async throws -> CmuxNextSettings.JSONValue {
        try await AppCompatBrowser.run(operation, tabID: tabID, services: services)
    }

    func perform(_ intent: CompatFrontendIntent) throws -> CmuxNextSettings.JSONValue {
        defer { afterIntent?() }
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
            // A window lists its own workspaces: a given workspace moves
            // into the new window; without one the window gets a new
            // workspace (opening once the daemon created it).
            guard let workspaceID else { return ["window_id": .string(services.windows.newWindow())] }
            guard let controller = services.windows.openWindow(workspaces: [workspaceID]) else {
                throw ControlError(code: "not_found", message: "Workspace not found: \(workspaceID)")
            }
            return ["window_id": .string(controller.state.id)]
        case .focusWindow(let windowID):
            let controller = try window(windowID)
            controller.window?.orderFront(nil)
            controller.window?.makeKey()
            if !services.environment.noActivate { NSApp.activate() }
            services.windows.didActivate(controller)
        case .closeWindow(let windowID):
            try window(windowID).close()
        }
        return [:]
    }

    private func window(_ id: String) throws -> WindowController {
        guard let controller = services.windows.controllers.first(where: { $0.state.id == id }) else {
            throw ControlError(code: "not_found", message: "Window not found: \(id)")
        }
        return controller
    }

    /// Shows `workspaceID` in the named window (which takes it), else in the
    /// window that lists it, else the active one, else a new window.
    /// Returns the window.
    @discardableResult
    private func show(workspaceID: String, windowID: String?) throws -> WindowController {
        guard services.workspace(id: workspaceID) != nil else {
            throw ControlError(code: "not_found", message: "Workspace not found: \(workspaceID)")
        }
        if let windowID {
            let controller = try window(windowID)
            services.windows.claim(workspaceID: workspaceID, in: controller.state)
            return controller
        }
        guard let controller = services.windows.reveal(workspaceID: workspaceID) else {
            throw ControlError(code: "not_found", message: "Workspace not found: \(workspaceID)")
        }
        return controller
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
