import Foundation
import CmuxControlSocket
import os

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
        let activate = Self.remoteTmuxActivate(from: params)
        let routing = remoteTmuxRouting(from: params)
        return v2VmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let windowTarget = await MainActor.run {
                self.remoteTmuxAttachWindowTarget(routing: routing)
            }
            let outcome = try await controller.attachHost(
                host: host,
                windowTarget: windowTarget,
                activate: activate
            )
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

    /// `remote.tmux.window` — mirror every tmux session on a host into a
    /// dedicated new window. Params: `host` (required), optional `port`,
    /// `identity_file`, and `activate`.
    nonisolated func v2RemoteTmuxWindow(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        let activate = Self.remoteTmuxActivate(from: params)
        return v2VmCall(id: id, timeoutSeconds: 60) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
            else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let outcome = try await controller.attachHost(
                host: host,
                windowTarget: .dedicatedNewWindow,
                activate: activate
            )
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

    private nonisolated static func remoteTmuxActivate(from params: [String: Any]) -> Bool {
        (params["activate"] as? Bool) ?? false
    }

    @MainActor
    func remoteTmuxAttachWindowTarget(
        routing: ControlRoutingSelectors
    ) -> RemoteTmuxAttachWindowTarget {
        if routing.hasWindowIDParam {
            return routing.windowID.map(RemoteTmuxAttachWindowTarget.explicitWindow)
                ?? .unresolvedExplicitWindow
        }
        let preferredWindowID = resolveTabManager(routing: routing)
            .flatMap { AppDelegate.shared?.windowId(for: $0) }
        return .contextualWindow(preferredWindowID)
    }

    /// `remote.tmux.detach` — detach a control client and remove its mirror workspace;
    /// leaves the remote session alive.
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

    /// `remote.tmux.pane_surfaces` — the tmux pane id → cmux surface id map for
    /// EVERY mirrored window, single-pane windows included.
    ///
    /// Content oracles need this. Reading "the focused surface" cannot verify a
    /// named pane: cmux does not follow tmux's active pane or current window
    /// (see handleActivePaneChanged, and %session-window-changed is only
    /// recorded), so a harness that runs `select-pane` and then reads the
    /// focused surface silently reads whatever pane the app already showed —
    /// and passes only when the two panes happen to share dimensions. With this
    /// map a harness reads the exact pane's surface (`surface.read_text` with
    /// `surface_id`) and compares it against that pane's `capture-pane`.
    ///
    /// Params: `host` (required), `session` (required).
    nonisolated func v2RemoteTmuxPaneSurfaces(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostAndSessionRequired", defaultValue: "host and session are required"))
        }
        return v2VmCall(id: id, timeoutSeconds: 10) {
            let entries: [[String: Any]]? = await MainActor.run {
                guard let mirror = AppDelegate.shared?.remoteTmuxController
                    .sessionMirror(host: host, sessionName: session) else { return nil }
                return mirror.paneSurfaceEntries()
            }
            guard let entries else {
                return ["host": host.destination, "session": session, "mirrored": false]
            }
            return [
                "host": host.destination,
                "session": session,
                "mirrored": true,
                "panes": entries,
            ]
        }
    }

    /// `remote.tmux.pane_grids` — per mirrored multi-pane window, each pane's
    /// tmux-assigned dims (from the layout tree) next to the grid its ghostty
    /// surface actually renders, plus the sizing state they converge toward
    /// (summed grid, last requested client size, structure/correction
    /// versions, remaining correction budget).
    ///
    /// Verification surface: a harness asserts renders match the assigned sizes through
    /// this instead of reading pixels off screenshots. Params: `host`
    /// (required), `session` (required).
    nonisolated func v2RemoteTmuxPaneGrids(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostAndSessionRequired", defaultValue: "host and session are required"))
        }
        return v2VmCall(id: id, timeoutSeconds: 10) {
            let snapshots: [RemoteTmuxWindowMirror.SizingSnapshot]? = await MainActor.run {
                AppDelegate.shared?.remoteTmuxController
                    .sessionMirror(host: host, sessionName: session)?
                    .sizingSnapshots()
            }
            guard let snapshots else {
                return ["host": host.destination, "session": session, "mirrored": false]
            }
            return [
                "host": host.destination,
                "session": session,
                "mirrored": true,
                "windows": snapshots.map { Self.sizingSnapshotPayload($0) },
            ]
        }
    }


    /// Serializes one window's ``RemoteTmuxWindowMirror/SizingSnapshot`` for the
    /// socket response. Per pane, `match` is present once the surface has a live
    /// grid: true iff rendered == assigned in both dimensions.
    nonisolated static func sizingSnapshotPayload(
        _ snapshot: RemoteTmuxWindowMirror.SizingSnapshot
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "window_id": "@\(snapshot.windowId)",
            "structure_version": snapshot.structureVersion,
            "zoomed": snapshot.zoomed,
            "base": ["cols": snapshot.baseCols, "rows": snapshot.baseRows],
            "panes": snapshot.panes.map { pane -> [String: Any] in
                var entry: [String: Any] = [
                    "pane_id": "%\(pane.paneId)",
                    "assigned": ["cols": pane.assignedCols, "rows": pane.assignedRows],
                    "has_panel": pane.hasPanel,
                ]
                if let inWindow = pane.viewInWindow { entry["view_in_window"] = inWindow }
                if let live = pane.surfaceLive { entry["surface_live"] = live }
                if let cols = pane.renderedCols, let rows = pane.renderedRows {
                    entry["rendered"] = ["cols": cols, "rows": rows]
                    // The render contract: exact on the enclosing split's
                    // axis, fill (>=, never smaller) on the cross axis —
                    // a smaller render means lost content, a larger one is
                    // background beyond the PTY.
                    let colsOk = pane.exactCols ? cols == pane.assignedCols : cols >= pane.assignedCols
                    let rowsOk = pane.exactRows ? rows == pane.assignedRows : rows >= pane.assignedRows
                    entry["match"] = colsOk && rowsOk
                }
                if let sample = pane.calibration {
                    var calibration: [String: Any] = [
                        "grid": ["cols": sample.columns, "rows": sample.rows],
                        "cell_px": ["w": sample.cellWidthPx, "h": sample.cellHeightPx],
                        "surface_px": ["w": sample.surfaceWidthPx, "h": sample.surfaceHeightPx],
                    ]
                    if let bounds = sample.viewBoundsPt {
                        calibration["view_pt"] = ["w": Double(bounds.width), "h": Double(bounds.height)]
                    }
                    if let scale = sample.backingScale {
                        calibration["scale"] = Double(scale)
                    }
                    entry["calibration"] = calibration
                }
                return entry
            },
        ]
        if let cols = snapshot.pushedColumns, let rows = snapshot.pushedRows {
            payload["pushed"] = ["cols": cols, "rows": rows]
        }
        payload["visible_for_sizing"] = snapshot.visibleForSizing
        if let container = snapshot.containerPt {
            payload["container_pt"] = ["w": Double(container.width), "h": Double(container.height)]
        }
        if let cols = snapshot.currentFCols, let rows = snapshot.currentFRows {
            payload["current_f"] = ["cols": cols, "rows": rows]
        }
        return payload
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
