import AppKit
import CmuxNextDesign
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
    /// Remote sessions' connections by `ControlSessions.key`.
    private nonisolated let sessionBox = Mutex<[String: DaemonConnection]>([:])
    private var connectionObservation: Task<Void, Never>?
    private var sessionObservation: Task<Void, Never>?
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
        let machines = services.machines
        sessionObservation = Task { [weak self] in
            let connections = Observations { () -> [String: DaemonConnection] in
                var map: [String: DaemonConnection] = [:]
                for daemon in machines.remoteDaemons {
                    if let connection = daemon.connection { map[ControlSessions.key(daemon)] = connection }
                }
                return map
            }
            for await map in connections {
                self?.sessionBox.withLock { $0 = map }
            }
        }
    }

    /// For `CompatService`'s session connection provider (off-main).
    nonisolated func connection(session: String) -> DaemonConnection? { sessionBox.withLock { $0[session] } }

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
            controller.focus.send(.selectTab(pane: paneID, tab: tabID, workspace: workspaceID, source: .cli))
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
            if let window = controller.window { WindowActivation.show(window, .focus) }
            services.windows.didActivate(controller)
        case .closeWindow(let windowID):
            try window(windowID).close()
        case .expectNotification:
            services.notifications.expectCreate()
        case .checkTabMove(let from, let to):
            if services.windows.crossesIncognito(from: from, to: to) {
                throw ControlError(code: "invalid_params", message: RefusalStrings.incognitoMismatch)
            }
        case .noteNotification(let id, let source):
            if let id {
                services.notifications.record(NotificationID(rawValue: id), source: NotificationSource(rawValue: source) ?? .agent)
            } else {
                services.notifications.createFailed()
            }
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
            if services.windows.registry.value.crossesIncognito([workspaceID], to: controller.state.id) {
                throw ControlError(code: "invalid_params", message: RefusalStrings.incognitoMismatch)
            }
            services.windows.claim(workspaceID: workspaceID, in: controller.state)
            return controller
        }
        guard let controller = services.windows.reveal(workspaceID: workspaceID) else {
            throw ControlError(code: "not_found", message: "Workspace not found: \(workspaceID)")
        }
        return controller
    }

    /// Focuses the pane now when its workspace is shown, else when the
    /// window's content switches to it (the coordinator remembers it).
    private func focus(paneID: String, workspaceID: String, in controller: WindowController) {
        controller.focus.send(.focusPane(paneID, workspace: workspaceID, source: .cli))
    }
}
