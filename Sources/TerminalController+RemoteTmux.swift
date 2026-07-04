import Foundation
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
    /// sidebar workspace (windows become tabs). Params: `host` (required).
    /// Mirrors into the host's dedicated mirror window when one is bound
    /// (#7363); otherwise into the key window's sidebar.
    nonisolated func v2RemoteTmuxMirror(id: Any?, params: [String: Any]) -> String {
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
            try await controller.mirrorHost(host: host)
            return ["host": host.destination, "mirrored": true]
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

    #if DEBUG
    /// `remote.tmux.test_exec` (DEBUG only) — runs a tmux argv with a given
    /// `TMUX_TMPDIR` inside the APP process and returns its exit/stdout/stderr.
    ///
    /// Exists solely so the sandboxed XCUITest runner can build and drive a
    /// hermetic lab tmux server WITHOUT touching the filesystem itself: the
    /// runner is confined to its container and cannot create `/tmp` dirs or
    /// spawn a tmux there, but the unsandboxed app can — so the runner sends
    /// every `new-session`/`split-window`/`resize-pane`/`list-panes` through
    /// this one socket verb, and the app owns the whole lab lifecycle in a
    /// path both its own tmux commands AND its ssh-shim attach can reach.
    /// Never compiled into release.
    nonisolated func v2RemoteTmuxTestExec(id: Any?, params: [String: Any]) -> String {
        guard let tmpdir = (params["tmpdir"] as? String),
              tmpdir.hasPrefix("/tmp/"), !tmpdir.contains("..")
        else {
            return v2Error(id: id, code: "invalid_params", message: "tmpdir must be under /tmp")
        }
        // JSON arrays arrive as [Any] (NSString elements), not [String] —
        // compactMap through Any so the cast never silently fails.
        guard let rawArgs = params["args"] as? [Any] else {
            return v2Error(id: id, code: "invalid_params", message: "args is required")
        }
        let args = rawArgs.compactMap { $0 as? String }
        guard args.count == rawArgs.count, !args.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "args must be non-empty strings")
        }
        // Only known tmux install paths: in allowAll socket mode this verb is
        // reachable by any local user, so it must not be a generic exec.
        let allowedBins: Set<String> = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        let bin = (params["bin"] as? String) ?? "/opt/homebrew/bin/tmux"
        guard allowedBins.contains(bin) else {
            return v2Error(id: id, code: "invalid_params", message: "bin must be a known tmux path")
        }
        return v2VmCall(id: id, timeoutSeconds: 30) {
            try? FileManager.default.createDirectory(atPath: tmpdir, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["TMUX_TMPDIR"] = tmpdir
            env.removeValue(forKey: "TMUX")
            proc.environment = env
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            try proc.run()
            // Drain both pipes BEFORE waiting so a child that writes past the
            // ~64KB pipe buffer can never deadlock against waitUntilExit —
            // without parking blocking reads on the cooperative pool (that
            // starves every later socket VM call). stderr accumulates on a
            // GCD readability handler; stdout is read to EOF on this thread.
            let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrBuffer.withLock { $0.append(chunk) }
                }
            }
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            proc.waitUntilExit()
            err.fileHandleForReading.readabilityHandler = nil
            // EOF race: collect whatever remains after the handler detaches.
            let trailing = err.fileHandleForReading.readDataToEndOfFile()
            let stderr = stderrBuffer.withLock { buffered -> String in
                var data = buffered
                data.append(trailing)
                return String(data: data, encoding: .utf8) ?? ""
            }
            // No "ok" key: the response encoder adds its own top-level "ok"
            // (call succeeded). tmux's exit status lives in "exit".
            return [
                "exit": Int(proc.terminationStatus),
                "stdout": stdout,
                "stderr": stderr,
            ]
        }
    }
    #endif

    #if DEBUG
    /// `remote.tmux.test_set_frame` (DEBUG only) — resizes a cmux window to an
    /// exact size from within the app.
    ///
    /// Exists for the sizing UI tests: driving window sizes with XCUITest
    /// mouse drags depends on the desktop around the app (an overlapping
    /// window from any other application invokes XCUITest's permission-dialog
    /// interruption scan, which crashes on elements whose accessibility value
    /// is numeric). `NSWindow.setFrame` drives the same resize path the
    /// window server does, deterministically. Never compiled into release.
    nonisolated func v2RemoteTmuxTestSetFrame(id: Any?, params: [String: Any]) -> String {
        guard let idString = params["window_id"] as? String,
              let windowId = UUID(uuidString: idString),
              let width = params["width"] as? Double, width > 100,
              let height = params["height"] as? Double, height > 100
        else {
            return v2Error(id: id, code: "invalid_params", message: "window_id, width, height are required")
        }
        // Generous timeout: the hop onto the main actor can wait out a busy
        // render/output burst in a test app running a dozen live panes.
        return v2VmCall(id: id, timeoutSeconds: 30) {
            // Read back the frame AFTER setFrame: AppKit clamps to min/max
            // content sizes and screen bounds, so the actual size is the only
            // trustworthy answer — callers assert on it rather than assuming
            // the request applied.
            let applied: CGSize? = await MainActor.run {
                guard let window = AppDelegate.shared?.windowForMainWindowId(windowId) else {
                    return nil
                }
                var frame = window.frame
                // Keep the top-left corner anchored so the window stays on screen.
                frame.origin.y += frame.size.height - height
                frame.size = CGSize(width: width, height: height)
                window.setFrame(frame, display: true, animate: false)
                return window.frame.size
            }
            guard let applied else {
                throw RemoteTmuxError.unreachable("window not found: \(idString)")
            }
            return [
                "applied_width": Double(applied.width),
                "applied_height": Double(applied.height),
            ]
        }
    }
    #endif

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
