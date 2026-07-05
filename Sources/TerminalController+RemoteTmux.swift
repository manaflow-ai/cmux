import Foundation
import CmuxControlSocket

/// Socket/CLI handlers for the remote-tmux (`ssh … tmux -CC`) beta feature.
///
/// These run on the socket worker (registered in `socketWorkerV2Methods`) so
/// the SSH round-trips never block the main actor. Each handler gates on the
/// `remoteTmux` beta flag and delegates to `AppDelegate`'s
/// ``RemoteTmuxController``.
extension TerminalController {
    /// `remote.tmux.sessions` — list the tmux sessions on a host.
    ///
    /// Params: `host` (required SSH destination/alias), optional `port` (Int),
    /// optional `identity_file` (String).
    nonisolated func v2RemoteTmuxSessions(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        return v2VmCall(id: id, timeoutSeconds: 30) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let sessions = try await controller.listSessions(host: host)
            return [
                "host": host.destination,
                "sessions": sessions.map { Self.sessionPayload($0) },
            ]
        }
    }

    /// Builds a ``RemoteTmuxHost`` from socket params (`host`, `port`, `identity_file`).
    ///
    /// Rejects a destination (or identity file) beginning with `-`: even with the
    /// `--` end-of-options guard in the argv builders, a dash-prefixed
    /// destination is never a legitimate SSH alias/`user@host`, and refusing it
    /// at the trust boundary is defense in depth against ssh option injection
    /// (`-oProxyCommand=…` → local command execution).
    nonisolated static func remoteTmuxHost(from params: [String: Any]) -> RemoteTmuxHost? {
        guard let destination = (params["host"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !destination.isEmpty,
            !destination.hasPrefix("-"),
            !Self.remoteTmuxValueHasHiddenCharacter(destination)
        else { return nil }
        let port = params["port"] as? Int
        // Reject an out-of-range port at the trust boundary (consistent with the
        // dash-prefix/hidden-char rejections above) instead of silently falling back
        // to the SSH default.
        if let port, !(1...65535).contains(port) { return nil }
        let identityFile = (params["identity_file"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let identityFile, identityFile.hasPrefix("-") { return nil }
        if let identityFile, Self.remoteTmuxValueHasHiddenCharacter(identityFile) { return nil }
        return RemoteTmuxHost(
            destination: destination,
            port: port,
            identityFile: (identityFile?.isEmpty == false) ? identityFile : nil
        )
    }

    /// Rejects control / format / separator scalars in an SSH destination or
    /// identity-file path. These hidden characters never appear in a legitimate
    /// `user@host` / alias / key path, and refusing them at the socket boundary
    /// blocks attempts to smuggle terminal escapes or obscure the real target —
    /// defense in depth alongside the dash-prefix rejection and the argv `--`
    /// end-of-options guard.
    nonisolated static func remoteTmuxValueHasHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    /// `remote.tmux.attach` — attach a `tmux -CC` control client to a session.
    ///
    /// Params: `host` (required), `session` (required tmux session name),
    /// optional `create` (Bool — attach-or-create). Returns the control surface id.
    nonisolated func v2RemoteTmuxAttach(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        guard let session = Self.remoteTmuxSessionName(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.sessionRequired", defaultValue: "session is required"))
        }
        let createIfMissing = (params["create"] as? Bool) ?? false
        return v2VmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            if let sshArgv = try await controller.attachControlStreamWhenReady(
                host: host,
                sessionName: session,
                createIfMissing: createIfMissing
            ) {
                return [
                    "host": host.destination,
                    "session": session,
                    "auth_required": true,
                    "ssh_argv": sshArgv,
                ]
            }
            return [
                "host": host.destination,
                "session": session,
                "attached": true,
            ]
        }
    }

    /// `remote.tmux.mirror` — mirror every tmux session on a host as its own
    /// sidebar workspace in the resolved window. Params: `host` (required),
    /// optional `port`, `identity_file`, `activate`, and routing selectors.
    nonisolated func v2RemoteTmuxMirror(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        let activate = (params["activate"] as? Bool) ?? false
        let routing = remoteTmuxRouting(from: params)
        return v2VmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let requestedManager = await MainActor.run { self.resolveTabManager(routing: routing) }
            let outcome = try await controller.attachHost(host: host, into: requestedManager, activate: activate)
            switch outcome {
            case .mirrored(let windowId, let workspaceIds):
                return [
                    "host": host.destination,
                    "mirrored": true,
                    "window_id": windowId.uuidString,
                    "workspace_ids": workspaceIds.map(\.uuidString),
                ]
            case .authRequired(let sshArgv):
                return [
                    "host": host.destination,
                    "auth_required": true,
                    "ssh_argv": sshArgv,
                ]
            }
        }
    }

    nonisolated func remoteTmuxRouting(from params: [String: Any]) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: v2HasNonNullParam(params, "window_id"),
            windowID: v2UUID(params, "window_id"),
            groupID: v2UUID(params, "group_id"),
            workspaceID: v2UUID(params, "workspace_id"),
            surfaceID: v2UUID(params, "surface_id")
                ?? v2UUID(params, "terminal_id")
                ?? v2UUID(params, "tab_id"),
            paneID: v2UUID(params, "pane_id")
        )
    }

    /// `remote.tmux.detach` — detach a control client (leaves the remote session alive).
    nonisolated func v2RemoteTmuxDetach(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostAndSessionRequired", defaultValue: "host and session are required"))
        }
        return v2VmCall(id: id, timeoutSeconds: 10) {
            try await MainActor.run {
                guard let controller = AppDelegate.shared?.remoteTmuxController else {
                    throw RemoteTmuxError.unreachable("app not ready")
                }
                controller.detach(host: host, sessionName: session)
            }
            return ["host": host.destination, "session": session, "detached": true]
        }
    }

    /// `remote.tmux.state` — report a control client's observed control-mode state.
    ///
    /// Diagnostics surface for verifying the ghostty → cmux event pipe end to end.
    nonisolated func v2RemoteTmuxState(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostAndSessionRequired", defaultValue: "host and session are required"))
        }
        return v2VmCall(id: id, timeoutSeconds: 10) {
            let snapshot: RemoteTmuxControlConnection.Snapshot? = await MainActor.run {
                AppDelegate.shared?.remoteTmuxController
                    .connection(host: host, sessionName: session)?
                    .snapshot()
            }
            guard let snapshot else {
                return ["host": host.destination, "session": session, "attached": false]
            }
            var paneBytes: [String: Int] = [:]
            for (paneId, count) in snapshot.paneOutputByteCounts {
                paneBytes["%\(paneId)"] = count
            }
            var payload: [String: Any] = [
                "host": host.destination,
                "session": session,
                "attached": true,
                "started": snapshot.started,
                "enter_received": snapshot.enterReceived,
                "exited": snapshot.exited,
                "window_count": snapshot.windowCount,
                "window_ids": snapshot.windowIDs,
                "total_output_bytes": snapshot.totalOutputBytes,
                "pane_output_bytes": paneBytes,
                "recent_events": snapshot.recentEvents,
            ]
            if let sessionId = snapshot.sessionId {
                payload["session_id"] = sessionId
            }
            return payload
        }
    }

    /// Extracts a required tmux session name from socket params.
    nonisolated static func remoteTmuxSessionName(from params: [String: Any]) -> String? {
        guard let session = (params["session"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !session.isEmpty
        else { return nil }
        return session
    }

    /// Serializes a session for the socket response.
    nonisolated static func sessionPayload(_ session: RemoteTmuxSession) -> [String: Any] {
        var dict: [String: Any] = [
            "id": session.id,
            "name": session.name,
            "windows": session.windowCount,
            "attached": session.attached,
        ]
        if let created = session.createdUnix {
            dict["created"] = created
        }
        return dict
    }
}
