internal import Foundation

/// The worker-lane RPC handler for the v2 `remote.tmux.*` control commands,
/// lifted byte-faithfully from the app-side `TerminalController.v2RemoteTmux*`
/// command handlers.
///
/// Owns the command logic for `remote.tmux.sessions`, `remote.tmux.attach`,
/// `remote.tmux.mirror`, `remote.tmux.window`, `remote.tmux.detach`, and
/// `remote.tmux.state`: the beta-flag gate, the SSH-injection-hardened param
/// parsing (the former `remoteTmuxHost(from:)` / `remoteTmuxSessionName(from:)`
/// / `remoteTmuxValueHasHiddenCharacter(_:)`), the per-command timeout +
/// `vm_error` rendering (the former `v2VmCall`), and the reply payload shaping
/// (the former `sessionPayload(_:)` and per-command dictionaries). It reaches the
/// live `RemoteTmuxController` strictly through the ``ControlRemoteTmuxReading``
/// seam and never imports the app target.
///
/// ## Isolation
///
/// `Sendable` and `async`, NOT `@MainActor`: these commands run on the
/// nonisolated socket-worker lane (`runsOnSocketWorker`). The legacy bodies ran
/// there too, fetching the controller with `MainActor.run(body:)` inside a
/// `v2VmCall` worker-thread block. Here the per-command main hop moves into the
/// seam (each member awaits the app conformer, which hops to main internally),
/// the timeout + error rendering move into ``runWithTimeout(seconds:_:)``, and
/// the single remaining worker-thread→async bridge lives in the app's worker-lane
/// dispatcher. The wire payloads (success, `vm_error`, `timeout`, the
/// `invalid_params` / `disabled` envelopes) are byte-identical to the legacy
/// ones.
public struct ControlRemoteTmuxWorker: Sendable {
    /// The live remote-tmux seam. Injected at construction.
    private let reading: any ControlRemoteTmuxReading

    /// The localized error strings, resolved app-side against the app bundle.
    private let strings: ControlRemoteTmuxStrings

    /// Creates a worker.
    ///
    /// - Parameters:
    ///   - reading: The remote-tmux seam to read/drive.
    ///   - strings: The localized error strings.
    public init(reading: any ControlRemoteTmuxReading, strings: ControlRemoteTmuxStrings) {
        self.reading = reading
        self.strings = strings
    }

    /// Runs one decoded request if it is a `remote.tmux.*` worker-lane command,
    /// returning the typed result; returns `nil` for any other method so the
    /// caller can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned method.
    public func handle(_ request: ControlRequest) async -> ControlCallResult? {
        switch request.method {
        case "remote.tmux.sessions":
            return await sessions(request.params)
        case "remote.tmux.attach":
            return await attach(request.params)
        case "remote.tmux.mirror":
            return await mirror(request.params)
        case "remote.tmux.window":
            return await window(request.params)
        case "remote.tmux.detach":
            return await detach(request.params)
        case "remote.tmux.state":
            return await state(request.params)
        case "remote.tmux.pane_grids":
            return await paneGrids(request.params)
        default:
            return nil
        }
    }

    // MARK: - Commands

    /// `remote.tmux.sessions` — list the tmux sessions on a host.
    private func sessions(_ params: [String: JSONValue]) async -> ControlCallResult {
        guard reading.isEnabled() else { return disabledError }
        guard let host = Self.remoteTmuxHost(from: params) else { return hostRequiredError }
        return await runWithTimeout(seconds: 30) {
            let sessions = try await reading.listSessions(host: host)
            return .object([
                "host": .string(host.destination),
                "sessions": .array(sessions.map { Self.sessionPayload($0) }),
            ])
        }
    }

    /// `remote.tmux.attach` — attach a `tmux -CC` control client to a session.
    private func attach(_ params: [String: JSONValue]) async -> ControlCallResult {
        guard reading.isEnabled() else { return disabledError }
        guard let host = Self.remoteTmuxHost(from: params) else { return hostRequiredError }
        guard let session = Self.remoteTmuxSessionName(from: params) else {
            return .err(code: "invalid_params", message: strings.sessionRequired, data: nil)
        }
        let createIfMissing = (params["create"]?.foundationObject as? Bool) ?? false
        return await runWithTimeout(seconds: 60) {
            if let sshArgv = try await reading.attachControlStreamWhenReady(
                host: host,
                sessionName: session,
                createIfMissing: createIfMissing
            ) {
                return .object([
                    "host": .string(host.destination),
                    "session": .string(session),
                    "auth_required": .bool(true),
                    "ssh_argv": .array(sshArgv.map { .string($0) }),
                ])
            }
            return .object([
                "host": .string(host.destination),
                "session": .string(session),
                "attached": .bool(true),
            ])
        }
    }

    /// `remote.tmux.mirror` — mirror every tmux session on a host as its own
    /// sidebar workspace.
    private func mirror(_ params: [String: JSONValue]) async -> ControlCallResult {
        guard reading.isEnabled() else { return disabledError }
        guard let host = Self.remoteTmuxHost(from: params) else { return hostRequiredError }
        return await runWithTimeout(seconds: 30) {
            try await reading.mirrorHost(host: host)
            return .object([
                "host": .string(host.destination),
                "mirrored": .bool(true),
            ])
        }
    }

    /// `remote.tmux.window` — open a dedicated cmux window mirroring every tmux
    /// session on a host.
    private func window(_ params: [String: JSONValue]) async -> ControlCallResult {
        guard reading.isEnabled() else { return disabledError }
        guard let host = Self.remoteTmuxHost(from: params) else { return hostRequiredError }
        let activate = (params["activate"]?.foundationObject as? Bool) ?? true
        // 60s (the CLI waits longer still) so a slow-but-valid BatchMode probe
        // completes instead of the app timing out first and turning an
        // auth-required result into an opaque timeout error.
        return await runWithTimeout(seconds: 60) {
            let outcome = try await reading.mirrorHostInNewWindow(host: host, activateWindow: activate)
            switch outcome {
            case .mirrored(let windowID):
                return .object([
                    "host": .string(host.destination),
                    "mirrored": .bool(true),
                    "window_id": .string(windowID),
                ])
            case .authRequired(let sshArgv):
                return .object([
                    "host": .string(host.destination),
                    "auth_required": .bool(true),
                    "ssh_argv": .array(sshArgv.map { .string($0) }),
                ])
            }
        }
    }

    /// `remote.tmux.detach` — detach a control client (leaves the remote session
    /// alive).
    private func detach(_ params: [String: JSONValue]) async -> ControlCallResult {
        guard reading.isEnabled() else { return disabledError }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return .err(code: "invalid_params", message: strings.hostAndSessionRequired, data: nil)
        }
        return await runWithTimeout(seconds: 10) {
            try await reading.detach(host: host, sessionName: session)
            return .object([
                "host": .string(host.destination),
                "session": .string(session),
                "detached": .bool(true),
            ])
        }
    }

    /// `remote.tmux.state` — report a control client's observed control-mode
    /// state.
    private func state(_ params: [String: JSONValue]) async -> ControlCallResult {
        guard reading.isEnabled() else { return disabledError }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return .err(code: "invalid_params", message: strings.hostAndSessionRequired, data: nil)
        }
        return await runWithTimeout(seconds: 10) {
            guard let snapshot = await reading.stateSnapshot(host: host, sessionName: session) else {
                return .object([
                    "host": .string(host.destination),
                    "session": .string(session),
                    "attached": .bool(false),
                ])
            }
            var paneBytes: [String: JSONValue] = [:]
            for (paneId, count) in snapshot.paneOutputByteCounts {
                paneBytes["%\(paneId)"] = .int(Int64(count))
            }
            var payload: [String: JSONValue] = [
                "host": .string(host.destination),
                "session": .string(session),
                "attached": .bool(true),
                "started": .bool(snapshot.started),
                "enter_received": .bool(snapshot.enterReceived),
                "exited": .bool(snapshot.exited),
                "window_count": .int(Int64(snapshot.windowCount)),
                "window_ids": .array(snapshot.windowIDs.map { .int(Int64($0)) }),
                "total_output_bytes": .int(Int64(snapshot.totalOutputBytes)),
                "pane_output_bytes": .object(paneBytes),
                "recent_events": .array(snapshot.recentEvents.map { .string($0) }),
            ]
            if let sessionId = snapshot.sessionId {
                payload["session_id"] = .int(Int64(sessionId))
            }
            return .object(payload)
        }
    }

    /// `remote.tmux.pane_grids` — per mirrored multi-pane window, each pane's
    /// tmux-assigned dims next to the grid its ghostty surface actually renders.
    private func paneGrids(_ params: [String: JSONValue]) async -> ControlCallResult {
        guard reading.isEnabled() else { return disabledError }
        guard let host = Self.remoteTmuxHost(from: params),
              let session = Self.remoteTmuxSessionName(from: params)
        else {
            return .err(code: "invalid_params", message: strings.hostAndSessionRequired, data: nil)
        }
        return await runWithTimeout(seconds: 10) {
            guard let snapshots = await reading.sizingSnapshots(host: host, sessionName: session) else {
                return .object([
                    "host": .string(host.destination),
                    "session": .string(session),
                    "mirrored": .bool(false),
                ])
            }
            return .object([
                "host": .string(host.destination),
                "session": .string(session),
                "mirrored": .bool(true),
                "windows": .array(snapshots.map { Self.sizingSnapshotPayload($0) }),
            ])
        }
    }

    // MARK: - Shared error envelopes

    /// The shared beta-flag-off error (the legacy `disabled` / "remote tmux beta
    /// is disabled" envelope).
    private var disabledError: ControlCallResult {
        .err(code: "disabled", message: strings.disabled, data: nil)
    }

    /// The shared missing-host error (the legacy `invalid_params` / "host is
    /// required" envelope).
    private var hostRequiredError: ControlCallResult {
        .err(code: "invalid_params", message: strings.hostRequired, data: nil)
    }

    // MARK: - Timeout bridge (the former v2VmCall)

    /// Runs `work` under a per-command timeout, rendering the same wire envelopes
    /// the legacy `v2VmCall` produced: success → `.ok`, a thrown error →
    /// `vm_error` + `String(describing:)`, and exceeding `seconds` → `timeout` +
    /// "VM request timed out after N seconds".
    ///
    /// The legacy `v2VmCall` blocked the worker thread on a semaphore with a
    /// timeout and cancelled the in-flight `Task` on expiry; this races the work
    /// against a sleep and cancels the loser, an isolation-only delta with a
    /// byte-identical observable result.
    private func runWithTimeout(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> JSONValue
    ) async -> ControlCallResult {
        await withTaskGroup(of: TimeoutOutcome.self) { group in
            group.addTask {
                do {
                    return .finished(.ok(try await work()))
                } catch is CancellationError {
                    // The timeout branch already produced the result; ignore the
                    // cancellation of the work task.
                    return .cancelled
                } catch {
                    return .finished(.err(
                        code: "vm_error",
                        message: String(describing: error),
                        data: nil
                    ))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            var result: ControlCallResult = .err(
                code: "vm_error",
                message: "unknown vm error",
                data: nil
            )
            for await outcome in group {
                switch outcome {
                case .finished(let value):
                    result = value
                    group.cancelAll()
                    return result
                case .timedOut:
                    group.cancelAll()
                    return .err(
                        code: "timeout",
                        message: "VM request timed out after \(Int(seconds)) seconds",
                        data: nil
                    )
                case .cancelled:
                    continue
                }
            }
            return result
        }
    }

    /// One arm's outcome inside ``runWithTimeout(seconds:_:)``.
    private enum TimeoutOutcome: Sendable {
        case finished(ControlCallResult)
        case timedOut
        case cancelled
    }

    // MARK: - Param parsing (the former remoteTmuxHost / remoteTmuxSessionName)

    /// Builds a ``ControlRemoteTmuxHost`` from socket params (`host`, `port`,
    /// `identity_file`), the byte-faithful twin of the legacy
    /// `TerminalController.remoteTmuxHost(from:)`.
    ///
    /// Rejects a destination (or identity file) beginning with `-`: even with the
    /// `--` end-of-options guard in the argv builders, a dash-prefixed
    /// destination is never a legitimate SSH alias/`user@host`, and refusing it
    /// at the trust boundary is defense in depth against ssh option injection
    /// (`-oProxyCommand=…` → local command execution). Also rejects an
    /// out-of-range port and any hidden control/format/separator scalar.
    ///
    /// The `as?` coercions read `JSONValue.foundationObject` so the result
    /// matches the legacy bodies, which received Foundation-bridged `[String: Any]`
    /// params.
    static func remoteTmuxHost(from params: [String: JSONValue]) -> ControlRemoteTmuxHost? {
        guard let destination = (params["host"]?.foundationObject as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !destination.isEmpty,
            !destination.hasPrefix("-"),
            !remoteTmuxValueHasHiddenCharacter(destination)
        else { return nil }
        let port = params["port"]?.foundationObject as? Int
        // Reject an out-of-range port at the trust boundary (consistent with the
        // dash-prefix/hidden-char rejections above) instead of silently falling
        // back to the SSH default.
        if let port, !(1...65535).contains(port) { return nil }
        let identityFile = (params["identity_file"]?.foundationObject as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let identityFile, identityFile.hasPrefix("-") { return nil }
        if let identityFile, remoteTmuxValueHasHiddenCharacter(identityFile) { return nil }
        return ControlRemoteTmuxHost(
            destination: destination,
            port: port,
            identityFile: (identityFile?.isEmpty == false) ? identityFile : nil
        )
    }

    /// Extracts a required tmux session name from socket params, the
    /// byte-faithful twin of the legacy `remoteTmuxSessionName(from:)`.
    static func remoteTmuxSessionName(from params: [String: JSONValue]) -> String? {
        guard let session = (params["session"]?.foundationObject as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !session.isEmpty
        else { return nil }
        return session
    }

    /// Rejects control / format / separator scalars in an SSH destination or
    /// identity-file path, the byte-faithful twin of the legacy
    /// `remoteTmuxValueHasHiddenCharacter(_:)`. These hidden characters never
    /// appear in a legitimate `user@host` / alias / key path, and refusing them
    /// at the socket boundary blocks attempts to smuggle terminal escapes or
    /// obscure the real target.
    static func remoteTmuxValueHasHiddenCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    /// Serializes a session for the socket response, the byte-faithful twin of
    /// the legacy `sessionPayload(_:)`: `id`, `name`, `windows`, `attached`, and
    /// `created` only when present.
    static func sessionPayload(_ session: ControlRemoteTmuxSession) -> JSONValue {
        var dict: [String: JSONValue] = [
            "id": .string(session.id),
            "name": .string(session.name),
            "windows": .int(Int64(session.windowCount)),
            "attached": .bool(session.attached),
        ]
        if let created = session.createdUnix {
            dict["created"] = .int(Int64(created))
        }
        return .object(dict)
    }

    /// Serializes one window's sizing snapshot for `remote.tmux.pane_grids`.
    static func sizingSnapshotPayload(_ snapshot: ControlRemoteTmuxSizingSnapshot) -> JSONValue {
        var payload: [String: JSONValue] = [
            "window_id": .string("@\(snapshot.windowId)"),
            "structure_version": .int(Int64(snapshot.structureVersion)),
            "zoomed": .bool(snapshot.zoomed),
            "base": .object([
                "cols": .int(Int64(snapshot.baseColumns)),
                "rows": .int(Int64(snapshot.baseRows)),
            ]),
            "panes": .array(snapshot.panes.map { pane -> JSONValue in
                var entry: [String: JSONValue] = [
                    "pane_id": .string("%\(pane.paneId)"),
                    "assigned": .object([
                        "cols": .int(Int64(pane.assignedColumns)),
                        "rows": .int(Int64(pane.assignedRows)),
                    ]),
                    "has_panel": .bool(pane.hasPanel),
                ]
                if let inWindow = pane.viewInWindow { entry["view_in_window"] = .bool(inWindow) }
                if let live = pane.surfaceLive { entry["surface_live"] = .bool(live) }
                if let cols = pane.renderedColumns, let rows = pane.renderedRows {
                    entry["rendered"] = .object([
                        "cols": .int(Int64(cols)),
                        "rows": .int(Int64(rows)),
                    ])
                    let colsOK = pane.exactColumns ? cols == pane.assignedColumns : cols >= pane.assignedColumns
                    let rowsOK = pane.exactRows ? rows == pane.assignedRows : rows >= pane.assignedRows
                    entry["match"] = .bool(colsOK && rowsOK)
                }
                if let sample = pane.calibration {
                    var calibration: [String: JSONValue] = [
                        "grid": .object([
                            "cols": .int(Int64(sample.columns)),
                            "rows": .int(Int64(sample.rows)),
                        ]),
                        "cell_px": .object([
                            "w": .int(Int64(sample.cellWidthPx)),
                            "h": .int(Int64(sample.cellHeightPx)),
                        ]),
                        "surface_px": .object([
                            "w": .int(Int64(sample.surfaceWidthPx)),
                            "h": .int(Int64(sample.surfaceHeightPx)),
                        ]),
                    ]
                    if let width = sample.viewWidthPt, let height = sample.viewHeightPt {
                        calibration["view_pt"] = .object(["w": .double(width), "h": .double(height)])
                    }
                    if let scale = sample.backingScale {
                        calibration["scale"] = .double(scale)
                    }
                    entry["calibration"] = .object(calibration)
                }
                return .object(entry)
            }),
            "visible_for_sizing": .bool(snapshot.visibleForSizing),
        ]
        if let cols = snapshot.pushedColumns, let rows = snapshot.pushedRows {
            payload["pushed"] = .object([
                "cols": .int(Int64(cols)),
                "rows": .int(Int64(rows)),
            ])
        }
        if let width = snapshot.containerWidthPt, let height = snapshot.containerHeightPt {
            payload["container_pt"] = .object(["w": .double(width), "h": .double(height)])
        }
        if let cols = snapshot.currentFColumns, let rows = snapshot.currentFRows {
            payload["current_f"] = .object([
                "cols": .int(Int64(cols)),
                "rows": .int(Int64(rows)),
            ])
        }
        return .object(payload)
    }
}
