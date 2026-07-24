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
    /// `remote.tmux.new_workspace` — create a NEW tmux session on the host backing
    /// a remote-tmux workspace, over its already-open control connection, so it
    /// links into the shared view and registers as its own cmux workspace (the CLI
    /// analogue of Cmd-N on a remote connection). Rides the existing stream, so it
    /// never opens a second SSH connection (which would hit single-use 2FA).
    ///
    /// Params: `workspace_id` (required UUID of an existing remote mirror, to locate
    /// the host + window), optional `name` (desired session title). On success
    /// returns the new `workspace_id` (+ `surface_id` when its first tab has
    /// reconciled); if the session was created but its mirror has not surfaced yet,
    /// returns `session_name` with `pending: true` (the session exists, so callers
    /// must not retry).
    nonisolated func v2RemoteTmuxNewWorkspace(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.workspaceRequired", defaultValue: "workspace_id is required"))
        }
        let name = v2String(params, "name")
        // Fail closed on a name tmux can't carry on the control stream (control/
        // newline bytes), rather than silently creating an auto-named session.
        if let name, RemoteTmuxHost.controlModeCommandName(name) == nil {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.invalidName", defaultValue: "name contains characters that are not allowed in a session name"))
        }
        // Outer timeout stays above createRemoteWorkspace's surface deadline so a
        // slow reconcile returns the partial (session-created) result rather than a
        // bare timeout that would hide the new session's name.
        return v2VmCall(id: id, timeoutSeconds: 45) {
            guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController }) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            let outcome = await controller.createRemoteWorkspace(referenceWorkspaceId: workspaceId, name: name)
            switch outcome {
            case let .created(newWorkspaceId, surfaceId):
                var payload: [String: Any] = [
                    "workspace_id": newWorkspaceId.uuidString,
                    "pending": false,
                ]
                if let surfaceId { payload["surface_id"] = surfaceId.uuidString }
                return payload
            case let .createdPending(sessionName):
                return [
                    "session_name": sessionName,
                    "pending": true,
                ]
            case .notLinked:
                throw RemoteTmuxError.unreachable("this workspace is not connected to a remote session")
            case .createFailed:
                throw RemoteTmuxError.unreachable("could not create a new session on the remote host")
            case .createIndeterminate:
                // The create reply was lost after the stream was connected: a session
                // may or may not have been created. Surface it as its own condition so
                // the CLI does not report a clean failure that invites a duplicate retry.
                throw RemoteTmuxError.unreachable("could not confirm whether the new remote session was created; list this host's sessions before retrying so you don't create a duplicate")
            }
        }
    }

    /// `remote.tmux.sessions` — list the tmux sessions on a host.
    ///
    /// Params: `host` (required SSH destination/alias), optional `port` (Int),
    /// optional `identity_file` (String).
    nonisolated func v2RemoteTmuxSessions(id: Any?, params: [String: Any]) -> String {
        guard RemoteTmuxController.isEnabled else {
            return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
        }
        guard let host = Self.remoteTmuxHost(from: params) else {
            if let brokerFailure = Self.remoteTmuxBrokerFailureMessage(from: params) {
                return v2Error(id: id, code: "invalid_params", message: brokerFailure)
            }
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
    nonisolated static func remoteTmuxHost(
        from params: [String: Any],
        selectBroker: (String?) -> RemoteTmuxBrokerSelection = {
            RemoteTmuxBrokerSnapshot.shared.select(requestedName: $0)
        }
    ) -> RemoteTmuxHost? {
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
        // A closed set, so an unknown transport is refused here rather than producing a
        // host nothing can spawn.
        guard let transport = RemoteTmuxTransportKind.parse(params["transport"] as? String) else {
            return nil
        }
        // The transport's own port, kept apart from ssh's: one-shots still ride ssh.
        let transportPort = params["transport_port"] as? Int
        if let transportPort, !(1...65535).contains(transportPort) { return nil }
        // A broker is chosen BY NAME from what the user declared under `remoteTmux.brokers`, never
        // described inline here. The socket is reachable by anything running as the user, so taking
        // an executable and its arguments from a parameter would be a wider local-execution surface
        // than the `-oProxyCommand=…` injection the checks above exist to refuse.
        //
        // A name that cannot be resolved refuses the host. Falling back to a direct connection would
        // reach the host by a route the user did not ask for, and the eventual failure would point at
        // the network instead of at the typo. ``remoteTmuxBrokerFailureMessage(from:)`` turns that
        // refusal into an error that says which of the three things went wrong.
        let broker: RemoteTmuxTransportBroker?
        switch selectBroker(params["transport_broker"] as? String) {
        case .none:
            broker = nil
        case .resolved(let resolved):
            // A broker only means anything to a transport that uses one. ssh deliberately ignores it
            // (ssh_config already has ProxyCommand/ProxyJump), so accepting the request here would
            // connect straight to the host — the exact "route the user did not choose" this boundary
            // refuses two paragraphs up, just arrived at by agreeing instead of by defaulting. And
            // since `transport` defaults to ssh, `--broker <name>` with no `--transport et` would hit
            // it. Refuse instead, and say which part disagreed.
            guard transport.usesTransportBroker else { return nil }
            broker = resolved
        case .unknown, .unusable, .malformed:
            return nil
        }
        return RemoteTmuxHost(
            destination: destination,
            port: port,
            identityFile: (identityFile?.isEmpty == false) ? identityFile : nil,
            transport: transport,
            transportPort: transportPort,
            transportBroker: broker
        )
    }

    /// Why a broker request was refused, or nil when none was made or it resolved.
    ///
    /// Three refusals with three different fixes, so they get three different messages: a name
    /// nobody declared is a typo or a missing entry, a declared-but-unusable one is a path to
    /// correct, and a name carrying hidden characters never could have matched a config key.
    /// Collapsing them into "host is required" sent people looking at the wrong parameter.
    nonisolated static func remoteTmuxBrokerFailureMessage(
        from params: [String: Any],
        selectBroker: (String?) -> RemoteTmuxBrokerSelection = {
            RemoteTmuxBrokerSnapshot.shared.select(requestedName: $0)
        }
    ) -> String? {
        switch selectBroker(params["transport_broker"] as? String) {
        case .none:
            return nil
        case .resolved:
            // The name resolved, but a transport that ignores brokers must not accept one silently —
            // see the refusal in `remoteTmuxHost(from:)`. Naming the transport is the useful part of
            // the message: the likeliest cause is `--broker` without `--transport et`.
            guard let transport = RemoteTmuxTransportKind.parse(params["transport"] as? String),
                  !transport.usesTransportBroker
            else { return nil }
            return String(
                localized: "socket.remoteTmux.brokerNotUsedByTransport",
                defaultValue: "the '\(transport.rawValue)' transport does not use a broker; pass --transport et to connect through one"
            )
        case .unknown(let name):
            return String(
                localized: "socket.remoteTmux.brokerUnknown",
                defaultValue: "no broker named '\(name)' is declared under remoteTmux.brokers in cmux.json"
            )
        case .unusable(let name, let reason):
            return String(
                localized: "socket.remoteTmux.brokerUnusable",
                defaultValue: "broker '\(name)' is declared but cannot be used: \(reason)"
            )
        case .malformed(let reason):
            return String(
                localized: "socket.remoteTmux.brokerMalformed",
                defaultValue: "transport_broker is not a usable name: \(reason)"
            )
        }
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
            if let brokerFailure = Self.remoteTmuxBrokerFailureMessage(from: params) {
                return v2Error(id: id, code: "invalid_params", message: brokerFailure)
            }
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        let createIfMissing = (params["create"] as? Bool) ?? false
        guard let session = Self.remoteTmuxSessionName(
            from: params,
            transport: host.transport,
            mode: .forCreateIfMissing(createIfMissing)
        ) else {
            return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.sessionRequired", defaultValue: "session is required"))
        }
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
            if let brokerFailure = Self.remoteTmuxBrokerFailureMessage(from: params) {
                return v2Error(id: id, code: "invalid_params", message: brokerFailure)
            }
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
            if let brokerFailure = Self.remoteTmuxBrokerFailureMessage(from: params) {
                return v2Error(id: id, code: "invalid_params", message: brokerFailure)
            }
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
            if let brokerFailure = Self.remoteTmuxBrokerFailureMessage(from: params) {
                return v2Error(id: id, code: "invalid_params", message: brokerFailure)
            }
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
            if let brokerFailure = Self.remoteTmuxBrokerFailureMessage(from: params) {
                return v2Error(id: id, code: "invalid_params", message: brokerFailure)
            }
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
            if let brokerFailure = Self.remoteTmuxBrokerFailureMessage(from: params) {
                return v2Error(id: id, code: "invalid_params", message: brokerFailure)
            }
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
            if let brokerFailure = Self.remoteTmuxBrokerFailureMessage(from: params) {
                return v2Error(id: id, code: "invalid_params", message: brokerFailure)
            }
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
    ///
    /// - Parameter mode: the attach mode this name will really be spawned with. It decides the
    ///   length bound, because the bound is derived from the command that gets sent and the
    ///   modes spell out different commands. Checking `.attach` for a request that then builds
    ///   `new-session -A -s` let an 890-byte name through the boundary and fail later in
    ///   `spawnProcess` as `launchFailed` at 929 bytes against a 928-byte budget.
    nonisolated static func remoteTmuxSessionName(
        from params: [String: Any],
        transport: RemoteTmuxTransportKind = .ssh,
        mode: RemoteTmuxControlAttachMode = .attach
    ) -> String? {
        guard let session = (params["session"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !session.isEmpty
        else { return nil }
        // Rejected here rather than discovered as a timeout. et types its command into a pty, so a
        // name long enough to push the line past MAX_CANON is never delivered: the shell runs
        // nothing and the attach dies with nothing to explain it. tmux happily accepts names of
        // ~1000 bytes, so this is reachable with a real session rather than only by abuse.
        if transport == .et,
           session.utf8.count > RemoteTmuxETTransportProfile.maxSessionNameBytes(mode: mode) {
            return nil
        }
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
