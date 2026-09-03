import Foundation
import CmuxControlSocket
import CmuxNestedTopology

/// Socket/CLI handlers for the native Herdr mirror (`remote.herdr.*`).
///
/// Twin of ``TerminalController+RemoteTmux``. Gates on ``RemoteHerdrController/isEnabled``
/// and never shells out to the herdr CLI.
extension TerminalController {
    private nonisolated static func remoteHerdrDisabledResponse(id: Any?) -> String {
        v2Error(
            id: id,
            code: "disabled",
            message: String(
                localized: "socket.remoteHerdr.disabled",
                defaultValue: "remote Herdr mirror beta is disabled"
            )
        )
    }

    private nonisolated static func remoteHerdrSocketPath(from params: [String: Any]) -> String? {
        RemoteHerdrLifecycle.validateSocketPath(
            (params["socket"] as? String) ?? (params["socket_path"] as? String)
        )
    }

    private nonisolated static func remoteHerdrSocketRequiredResponse(id: Any?) -> String {
        v2Error(
            id: id,
            code: "invalid_params",
            message: String(
                localized: "socket.remoteHerdr.socketRequired",
                defaultValue: "socket is required"
            )
        )
    }

    private nonisolated static func remoteHerdrSocketAndSessionRequiredResponse(id: Any?) -> String {
        v2Error(
            id: id,
            code: "invalid_params",
            message: String(
                localized: "socket.remoteHerdr.socketAndSessionRequired",
                defaultValue: "socket and session are required"
            )
        )
    }

    private nonisolated static func remoteHerdrSocketAndSession(
        from params: [String: Any]
    ) -> (socket: String, session: String)? {
        guard let socket = remoteHerdrSocketPath(from: params),
              let session = RemoteHerdrLifecycle.validateSessionName(params["session"] as? String)
        else { return nil }
        return (socket, session)
    }

    private nonisolated static func remoteHerdrInvalidSessionResponse(id: Any?) -> String {
        v2Error(
            id: id,
            code: "invalid_params",
            message: String(
                localized: "socket.remoteHerdr.sessionInvalid",
                defaultValue: "session is invalid"
            )
        )
    }

    /// Encodes one remote.herdr result without raw `String(describing:)` diagnostics.
    private nonisolated func remoteHerdrEncodeResult(
        id: Any?,
        timeoutSeconds: TimeInterval,
        _ result: Result<[String: Any], Error>?
    ) -> String {
        switch result {
        case .success(let payload):
            return v2Ok(id: id, result: payload)
        case .failure(let error):
            return v2Error(
                id: id,
                code: RemoteHerdrHostError.publicCode(for: error),
                message: RemoteHerdrHostError.publicMessage(for: error)
            )
        case nil:
            return v2Error(
                id: id,
                code: "timeout",
                message: "VM request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
    }

    /// Socket-worker path returns immediately and writes later. In-process
    /// ``handleSocketLine`` still waits so callers receive a string.
    private nonisolated func remoteHerdrVmCall(
        id: Any?,
        timeoutSeconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> [String: Any]
    ) -> String {
        if let pending = TerminalController.currentRemoteHerdrPendingSocketReply() {
            Task { [weak self] in
                guard let self else { return }
                let encoded: String
                do {
                    let payload = try await withThrowingTaskGroup(of: [String: Any].self) { group in
                        group.addTask { try await work() }
                        group.addTask {
                            try await Task.sleep(for: .seconds(timeoutSeconds))
                            throw CancellationError()
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                    encoded = self.remoteHerdrEncodeResult(id: id, timeoutSeconds: timeoutSeconds, .success(payload))
                } catch is CancellationError {
                    encoded = self.remoteHerdrEncodeResult(id: id, timeoutSeconds: timeoutSeconds, nil)
                } catch {
                    encoded = self.remoteHerdrEncodeResult(id: id, timeoutSeconds: timeoutSeconds, .failure(error))
                }
                self.completeRemoteHerdrSocketReply(
                    encoded,
                    socket: pending.socket,
                    command: pending.command
                )
            }
            return TerminalController.remoteHerdrDeferredReplyToken
        }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<[String: Any], Error>?
        let task = Task {
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return remoteHerdrEncodeResult(id: id, timeoutSeconds: timeoutSeconds, nil)
        }
        return remoteHerdrEncodeResult(id: id, timeoutSeconds: timeoutSeconds, result)
    }

    /// `remote.herdr.sessions` — list Herdr workspaces on a Unix socket.
    nonisolated func v2RemoteHerdrSessions(id: Any?, params: [String: Any]) -> String {
        guard RemoteHerdrController.isEnabled else {
            return Self.remoteHerdrDisabledResponse(id: id)
        }
        guard let socket = Self.remoteHerdrSocketPath(from: params) else {
            return Self.remoteHerdrSocketRequiredResponse(id: id)
        }
        return remoteHerdrVmCall(id: id, timeoutSeconds: 30) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteHerdrController })
            else {
                throw RemoteHerdrHostError.unreachable("app not ready")
            }
            let sessions = try await controller.listSessions(socketPath: socket)
            return [
                "socket": socket,
                "sessions": sessions.map { $0.payload() },
            ]
        }
    }

    /// `remote.herdr.attach` / `remote.herdr.mirror` — mirror sessions into the resolved window.
    nonisolated func v2RemoteHerdrAttach(id: Any?, params: [String: Any]) -> String {
        remoteHerdrAttachOrWindow(id: id, params: params, dedicated: false)
    }

    /// `remote.herdr.window` — mirror into a dedicated new window.
    nonisolated func v2RemoteHerdrWindow(id: Any?, params: [String: Any]) -> String {
        remoteHerdrAttachOrWindow(id: id, params: params, dedicated: true)
    }

    nonisolated func v2RemoteHerdrMirror(id: Any?, params: [String: Any]) -> String {
        remoteHerdrAttachOrWindow(id: id, params: params, dedicated: false)
    }

    private nonisolated func remoteHerdrAttachOrWindow(
        id: Any?,
        params: [String: Any],
        dedicated: Bool
    ) -> String {
        guard RemoteHerdrController.isEnabled else {
            return Self.remoteHerdrDisabledResponse(id: id)
        }
        guard let socket = Self.remoteHerdrSocketPath(from: params) else {
            return Self.remoteHerdrSocketRequiredResponse(id: id)
        }
        let activate = (params["activate"] as? Bool) ?? false
        let session: String?
        if params.keys.contains("session") {
            guard let validated = RemoteHerdrLifecycle.validateSessionName(params["session"] as? String)
            else {
                return Self.remoteHerdrInvalidSessionResponse(id: id)
            }
            session = validated
        } else {
            session = nil
        }
        let target = RemoteHerdrAttachWindowTarget.fromParams(params, dedicated: dedicated)
        return remoteHerdrVmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteHerdrController })
            else {
                throw RemoteHerdrHostError.unreachable("app not ready")
            }
            // Resolve contextual targets with live window ids when needed.
            let resolvedTarget: RemoteHerdrAttachWindowTarget = await MainActor.run {
                if dedicated { return target }
                if target.kind == "contextual", target.windowID == nil {
                    let preferred = self.remoteHerdrPreferredWindowID(from: params)
                    return RemoteHerdrAttachWindowTarget(kind: "contextual", windowID: preferred)
                }
                return target
            }
            return try await controller.attachHost(
                socketPath: socket,
                windowTarget: resolvedTarget,
                activate: activate,
                sessionFilter: session
            )
        }
    }

    @MainActor
    private func remoteHerdrPreferredWindowID(from params: [String: Any]) -> String? {
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: v2HasNonNullParam(params, "window_id"),
            windowID: v2UUID(params, "window_id"),
            groupID: v2UUID(params, "group_id"),
            workspaceID: v2UUID(params, "workspace_id"),
            surfaceID: v2UUID(params, "surface_id")
                ?? v2UUID(params, "terminal_id")
                ?? v2UUID(params, "tab_id"),
            paneID: v2UUID(params, "pane_id")
        )
        return resolveTabManager(routing: routing)
            .flatMap { AppDelegate.shared?.windowId(for: $0)?.uuidString }
    }

    /// `remote.herdr.detach` — detach and remove mirror workspace; leave Herdr running.
    nonisolated func v2RemoteHerdrDetach(id: Any?, params: [String: Any]) -> String {
        guard RemoteHerdrController.isEnabled else {
            return Self.remoteHerdrDisabledResponse(id: id)
        }
        guard let resolved = Self.remoteHerdrSocketAndSession(from: params) else {
            return Self.remoteHerdrSocketAndSessionRequiredResponse(id: id)
        }
        return remoteHerdrVmCall(id: id, timeoutSeconds: 10) {
            await MainActor.run {
                AppDelegate.shared?.remoteHerdrController.detach(
                    socketPath: resolved.socket,
                    sessionID: resolved.session
                )
            }
            return [
                "socket": resolved.socket,
                "session": resolved.session,
                "detached": true,
                "server_stopped": false,
            ]
        }
    }

    /// `remote.herdr.state` — mirrored session diagnostics.
    nonisolated func v2RemoteHerdrState(id: Any?, params: [String: Any]) -> String {
        guard RemoteHerdrController.isEnabled else {
            return Self.remoteHerdrDisabledResponse(id: id)
        }
        guard let resolved = Self.remoteHerdrSocketAndSession(from: params) else {
            return Self.remoteHerdrSocketAndSessionRequiredResponse(id: id)
        }
        return remoteHerdrVmCall(id: id, timeoutSeconds: 10) {
            await MainActor.run {
                AppDelegate.shared?.remoteHerdrController.statePayload(
                    socketPath: resolved.socket,
                    sessionID: resolved.session
                ) ?? [
                    "socket": resolved.socket,
                    "session": resolved.session,
                    "attached": false,
                    "mirrored": false,
                ]
            }
        }
    }

    /// `remote.herdr.pane_surfaces` — pane id → surface id map.
    nonisolated func v2RemoteHerdrPaneSurfaces(id: Any?, params: [String: Any]) -> String {
        guard RemoteHerdrController.isEnabled else {
            return Self.remoteHerdrDisabledResponse(id: id)
        }
        guard let resolved = Self.remoteHerdrSocketAndSession(from: params) else {
            return Self.remoteHerdrSocketAndSessionRequiredResponse(id: id)
        }
        return remoteHerdrVmCall(id: id, timeoutSeconds: 10) {
            let panes = await MainActor.run {
                AppDelegate.shared?.remoteHerdrController.paneSurfaceEntries(
                    socketPath: resolved.socket,
                    sessionID: resolved.session
                ) ?? []
            }
            return [
                "socket": resolved.socket,
                "session": resolved.session,
                "mirrored": !panes.isEmpty,
                "panes": panes,
            ]
        }
    }

    /// `remote.herdr.pane_grids` — assigned vs rendered grids per pane.
    nonisolated func v2RemoteHerdrPaneGrids(id: Any?, params: [String: Any]) -> String {
        guard RemoteHerdrController.isEnabled else {
            return Self.remoteHerdrDisabledResponse(id: id)
        }
        guard let resolved = Self.remoteHerdrSocketAndSession(from: params) else {
            return Self.remoteHerdrSocketAndSessionRequiredResponse(id: id)
        }
        return remoteHerdrVmCall(id: id, timeoutSeconds: 10) {
            let windows = await MainActor.run {
                AppDelegate.shared?.remoteHerdrController.paneGrids(
                    socketPath: resolved.socket,
                    sessionID: resolved.session
                ) ?? []
            }
            return [
                "socket": resolved.socket,
                "session": resolved.session,
                "mirrored": !windows.isEmpty,
                "windows": windows,
            ]
        }
    }
}
