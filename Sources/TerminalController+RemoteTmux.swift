import Foundation

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
            return v2Error(id: id, code: "disabled", message: "remote tmux beta is disabled")
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: "host is required")
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
            !destination.hasPrefix("-")
        else { return nil }
        let port = params["port"] as? Int
        let identityFile = (params["identity_file"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let identityFile, identityFile.hasPrefix("-") { return nil }
        return RemoteTmuxHost(
            destination: destination,
            port: port,
            identityFile: (identityFile?.isEmpty == false) ? identityFile : nil
        )
    }

    /// `remote.tmux.attach` — attach a `tmux -CC` control client to a session.
    ///
    /// Params: `host` (required), `session` (required tmux session name),
    /// optional `create` (Bool — attach-or-create). Returns the control surface id.
    nonisolated func v2RemoteTmuxAttach(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: "remote tmux beta is disabled")
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: "host is required")
        }
        guard let session = Self.remoteTmuxSessionName(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: "session is required")
        }
        let createIfMissing = (params["create"] as? Bool) ?? false
        return v2VmCall(id: id, timeoutSeconds: 20) {
            try await MainActor.run {
                guard let controller = AppDelegate.shared?.remoteTmuxController else {
                    throw RemoteTmuxError.unreachable("app not ready")
                }
                _ = try controller.attach(
                    host: host,
                    sessionName: session,
                    createIfMissing: createIfMissing
                )
            }
            return [
                "host": host.destination,
                "session": session,
                "attached": true,
            ]
        }
    }

    /// `remote.tmux.open` — attach a session and mirror its active pane as a
    /// live display tab in the current workspace (first sidebar-mirroring step).
    nonisolated func v2RemoteTmuxOpen(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: "remote tmux beta is disabled")
        }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return v2Error(id: id, code: "invalid_params", message: "host and session are required")
        }
        return v2VmCall(id: id, timeoutSeconds: 20) {
            try await MainActor.run {
                guard let controller = AppDelegate.shared?.remoteTmuxController else {
                    throw RemoteTmuxError.unreachable("app not ready")
                }
                try controller.openActivePane(host: host, sessionName: session)
            }
            return ["host": host.destination, "session": session, "opened": true]
        }
    }

    /// `remote.tmux.mirror` — mirror every tmux session on a host as its own
    /// sidebar workspace (windows become tabs). Params: `host` (required).
    nonisolated func v2RemoteTmuxMirror(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: "remote tmux beta is disabled")
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: "host is required")
        }
        return v2VmCall(id: id, timeoutSeconds: 30) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            try await controller.mirrorHost(host: host)
            return ["host": host.destination, "mirrored": true]
        }
    }

    /// `remote.tmux.detach` — detach a control client (leaves the remote session alive).
    nonisolated func v2RemoteTmuxDetach(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: "remote tmux beta is disabled")
        }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return v2Error(id: id, code: "invalid_params", message: "host and session are required")
        }
        return v2VmCall(id: id, timeoutSeconds: 10) {
            await MainActor.run {
                AppDelegate.shared?.remoteTmuxController.detach(host: host, sessionName: session)
            }
            return ["host": host.destination, "session": session, "detached": true]
        }
    }

    /// `remote.tmux.state` — report a control client's observed control-mode state.
    ///
    /// Diagnostics surface for verifying the ghostty → cmux event pipe end to end.
    nonisolated func v2RemoteTmuxState(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: "remote tmux beta is disabled")
        }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return v2Error(id: id, code: "invalid_params", message: "host and session are required")
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
