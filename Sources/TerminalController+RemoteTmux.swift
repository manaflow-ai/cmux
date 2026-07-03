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

    /// `remote.tmux.attach_here` — mirror every tmux session on a host as plain
    /// workspaces in the CURRENT window (the default `cmux ssh-tmux` entry point).
    ///
    /// Params: `host` (required), optional `port` (Int), optional `identity_file`
    /// (String), optional `activate` (Bool, default `true`).
    ///
    /// Returns `{mirrored: true, window_id}` on success, or
    /// `{auth_required: true, ssh_argv: […]}` when the host needs interactive
    /// authentication (the CLI runs `ssh_argv` in the user's terminal and retries).
    nonisolated func v2RemoteTmuxAttachHere(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        let activate = (params["activate"] as? Bool) ?? true
        return v2VmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let outcome = try await controller.mirrorHostInCurrentWindow(host: host, activateWindow: activate)
            switch outcome {
            case .mirrored(let windowId):
                return [
                    "host": host.destination,
                    "mirrored": true,
                    "window_id": windowId.uuidString,
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

    /// `remote.tmux.window` — open a dedicated cmux window mirroring every tmux
    /// session on a host (the `cmux ssh-tmux` CLI entry point).
    ///
    /// Params: `host` (required), optional `port` (Int), optional `identity_file`
    /// (String), optional `activate` (Bool, default `true`).
    ///
    /// Returns `{mirrored: true, window_id}` on success, or
    /// `{auth_required: true, ssh_argv: […]}` when the host needs interactive
    /// authentication. cmux's control client uses plain pipes and cannot prompt,
    /// so the CLI runs `ssh_argv` in the user's terminal (where the tty makes
    /// password / host-key / MFA / FIDO prompts work) to open the shared
    /// ControlMaster, then re-issues this command — which now succeeds by
    /// multiplexing over the authenticated master.
    nonisolated func v2RemoteTmuxWindow(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        let activate = (params["activate"] as? Bool) ?? true
        // 60s (the CLI waits longer still) so a slow-but-valid BatchMode probe
        // completes instead of the app timing out first and turning an
        // auth-required result into an opaque timeout error.
        return v2VmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let outcome = try await controller.mirrorHostInNewWindow(host: host, activateWindow: activate)
            switch outcome {
            case .mirrored(let windowId):
                return [
                    "host": host.destination,
                    "mirrored": true,
                    "window_id": windowId.uuidString,
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
