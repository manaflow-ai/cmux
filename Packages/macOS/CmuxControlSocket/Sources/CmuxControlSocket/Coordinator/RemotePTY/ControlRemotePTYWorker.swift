internal import Foundation

/// The worker-lane RPC handler for the v2 `workspace.remote.pty_*` control
/// commands, lifted byte-faithfully from `TerminalController.v2WorkspaceRemotePTY*`.
///
/// Owns the command logic for `workspace.remote.pty_sessions`,
/// `workspace.remote.pty_close`, `workspace.remote.pty_detach`,
/// `workspace.remote.pty_bridge`, and `workspace.remote.pty_resize`: the param
/// validation (`session_id` / `attachment_id` / `attachment_token` presence,
/// positive `cols`/`rows`, the `all_workspaces` / `allow_moved_surface` boolean
/// checks), the per-command controller calls, the reply payload shaping (the
/// former `v2RemotePTYTargetPayload` / `v2RemotePTYSessionPayload` plus per-command
/// dictionaries), and the `remote_pty_error` rendering (the former
/// `v2RemotePTYUserFacingErrorMessage`). It reaches the live window/workspace graph
/// strictly through ``ControlRemotePTYReading`` and each workspace's controller
/// through ``ControlRemotePTYControlling``; it never imports the app target.
///
/// ## Isolation
///
/// `Sendable` and synchronous, NOT `@MainActor` and NOT `async`: these commands
/// ran on the nonisolated socket-worker lane (`runsOnSocketWorker`) and called the
/// controller synchronously (each call blocks the worker thread on the controller
/// queue with the legacy timeout). The per-command main hop for target resolution
/// lives inside the seam (the conformer uses `v2MainSync`); the controller's own
/// blocking-hop contract is unchanged. The wire payloads (`.ok` success bodies,
/// every `remote_pty_error` / `invalid_params` / `not_found` envelope) are
/// byte-identical to the legacy ones.
public struct ControlRemotePTYWorker: Sendable {
    /// The live window/workspace/surface resolution seam. Injected at construction.
    private let reading: any ControlRemotePTYReading

    /// Creates a worker.
    ///
    /// - Parameter reading: The live-state resolution seam.
    public init(reading: any ControlRemotePTYReading) {
        self.reading = reading
    }

    /// Runs one decoded request if it is a `workspace.remote.pty_*` worker-lane
    /// command, returning the typed result; returns `nil` for any other method so
    /// the caller can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned method.
    public func handle(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "workspace.remote.pty_sessions":
            return sessions(request.params)
        case "workspace.remote.pty_close":
            return close(request.params)
        case "workspace.remote.pty_detach":
            return detach(request.params)
        case "workspace.remote.pty_bridge":
            return bridge(request.params)
        case "workspace.remote.pty_resize":
            return resize(request.params)
        default:
            return nil
        }
    }

    // MARK: - Commands

    /// `workspace.remote.pty_sessions` — list a workspace's (or every remote
    /// workspace's) persistent PTY sessions.
    private func sessions(_ params: [String: JSONValue]) -> ControlCallResult {
        if Self.hasNonNullParam(params, "all_workspaces"), Self.bool(params, "all_workspaces") == nil {
            return .err(code: "invalid_params", message: "Missing or invalid all_workspaces", data: nil)
        }
        let allWorkspaces = Self.bool(params, "all_workspaces") ?? false
        let workspaceSelection = reading.requestedWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        let surfaceSelection = reading.requestedSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }
        let requestedWorkspaceID = workspaceSelection.workspaceID
        if allWorkspaces, requestedWorkspaceID != nil {
            return .err(
                code: "invalid_params",
                message: "all_workspaces cannot be combined with workspace_id",
                data: nil
            )
        }
        if allWorkspaces {
            let targets = reading.allWorkspaceTargets()
            var sessions: [JSONValue] = []
            var errors: [JSONValue] = []
            for target in targets {
                guard let controller = target.controller else {
                    var payload = Self.targetPayload(target)
                    payload["error"] = .string("remote connection is not active")
                    errors.append(.object(payload))
                    continue
                }
                do {
                    let workspaceSessions = try controller.listPTYSessions()
                    sessions.append(contentsOf: workspaceSessions.map {
                        Self.sessionPayload($0, target: target)
                    })
                } catch {
                    var payload = Self.targetPayload(target)
                    payload["error"] = .string(Self.userFacingErrorMessage(error))
                    errors.append(.object(payload))
                }
            }
            return .ok(.object([
                "all_workspaces": .bool(true),
                "workspace_count": .int(Int64(targets.count)),
                "sessions": .array(sessions),
                "errors": .array(errors),
            ]))
        }

        let resolved = reading.resolveTarget(
            params: params,
            requestedWorkspaceID: requestedWorkspaceID,
            preferredSurfaceID: surfaceSelection.surfaceID
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
            ]))
        }

        do {
            let sessions = try controller.listPTYSessions()
            var payload = Self.targetPayload(target)
            payload["sessions"] = .array(sessions.map { Self.sessionPayload($0, target: target) })
            return .ok(.object(payload))
        } catch {
            return .err(code: "remote_pty_error", message: Self.userFacingErrorMessage(error), data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
            ]))
        }
    }

    /// `workspace.remote.pty_close` — close one persistent PTY session.
    private func close(_ params: [String: JSONValue]) -> ControlCallResult {
        let workspaceSelection = reading.requestedWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = Self.trimmedRawString(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let surfaceSelection = reading.requestedSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }

        let resolved = reading.resolveTarget(
            params: params,
            requestedWorkspaceID: workspaceSelection.workspaceID,
            preferredSurfaceID: surfaceSelection.surfaceID
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
                "session_id": .string(sessionID),
            ]))
        }

        do {
            try controller.closePTYSession(sessionID: sessionID)
            var payload = Self.targetPayload(target)
            payload["session_id"] = .string(sessionID)
            payload["closed"] = .bool(true)
            return .ok(.object(payload))
        } catch {
            return .err(code: "remote_pty_error", message: Self.userFacingErrorMessage(error), data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
                "session_id": .string(sessionID),
            ]))
        }
    }

    /// `workspace.remote.pty_detach` — detach one persistent PTY attachment.
    private func detach(_ params: [String: JSONValue]) -> ControlCallResult {
        let workspaceSelection = reading.requestedWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = Self.trimmedRawString(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        guard let attachmentID = Self.trimmedRawString(params, "attachment_id"), !attachmentID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_id", data: nil)
        }
        guard let attachmentToken = Self.trimmedRawString(params, "attachment_token"), !attachmentToken.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_token", data: nil)
        }
        let surfaceSelection = reading.requestedSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }

        let resolved = reading.resolveTarget(
            params: params,
            requestedWorkspaceID: workspaceSelection.workspaceID,
            preferredSurfaceID: surfaceSelection.surfaceID
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
                "session_id": .string(sessionID),
                "attachment_id": .string(attachmentID),
            ]))
        }

        do {
            try controller.detachPTYSession(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken
            )
            var payload = Self.targetPayload(target)
            payload["session_id"] = .string(sessionID)
            payload["attachment_id"] = .string(attachmentID)
            payload["detached"] = .bool(true)
            return .ok(.object(payload))
        } catch {
            return .err(code: "remote_pty_error", message: Self.userFacingErrorMessage(error), data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
                "session_id": .string(sessionID),
                "attachment_id": .string(attachmentID),
            ]))
        }
    }

    /// `workspace.remote.pty_bridge` — start (or reuse) a loopback PTY bridge.
    private func bridge(_ params: [String: JSONValue]) -> ControlCallResult {
        let workspaceSelection = reading.requestedWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = Self.trimmedRawString(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let attachmentID = Self.trimmedRawString(params, "attachment_id")
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString.lowercased()
        let command = Self.trimmedRawString(params, "command")
        let requireExisting = Self.bool(params, "require_existing") ?? false
        let waitForReady = Self.bool(params, "wait_for_ready") ?? false
        let surfaceSelection = reading.requestedSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }
        let preferredSurfaceID = surfaceSelection.surfaceID ?? UUID(uuidString: attachmentID)

        let controllerDeadline = Date().addingTimeInterval(waitForReady ? 90.0 : 8.0)
        let resolved = waitForReady
            ? reading.resolveTargetWaitingForController(
                params: params,
                requestedWorkspaceID: workspaceSelection.workspaceID,
                preferredSurfaceID: preferredSurfaceID,
                deadlineUnixSeconds: controllerDeadline.timeIntervalSince1970
            )
            : reading.resolveTarget(
                params: params,
                requestedWorkspaceID: workspaceSelection.workspaceID,
                preferredSurfaceID: preferredSurfaceID
            )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
                "session_id": .string(sessionID),
                "attachment_id": .string(attachmentID),
            ]))
        }

        do {
            let endpoint = try controller.startPTYBridge(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command?.isEmpty == true ? nil : command,
                requireExisting: requireExisting,
                waitForReady: waitForReady,
                timeout: waitForReady ? 90.0 : max(0.1, controllerDeadline.timeIntervalSinceNow)
            )
            var payload = Self.targetPayload(target)
            payload["host"] = .string(endpoint.host)
            payload["port"] = .int(Int64(endpoint.port))
            payload["token"] = .string(endpoint.token)
            payload["session_id"] = .string(endpoint.sessionID)
            payload["attachment_id"] = .string(endpoint.attachmentID)
            return .ok(.object(payload))
        } catch {
            return .err(code: "remote_pty_error", message: Self.userFacingErrorMessage(error), data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
                "session_id": .string(sessionID),
                "attachment_id": .string(attachmentID),
            ]))
        }
    }

    /// `workspace.remote.pty_resize` — resize one persistent PTY attachment.
    private func resize(_ params: [String: JSONValue]) -> ControlCallResult {
        let workspaceSelection = reading.requestedWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = Self.trimmedRawString(params, "session_id"), !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        guard let attachmentID = Self.trimmedRawString(params, "attachment_id"), !attachmentID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_id", data: nil)
        }
        guard let attachmentToken = Self.trimmedRawString(params, "attachment_token"), !attachmentToken.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_token", data: nil)
        }
        guard let cols = Self.strictInt(params, "cols"), cols > 0,
              let rows = Self.strictInt(params, "rows"), rows > 0 else {
            return .err(code: "invalid_params", message: "cols and rows must be positive integers", data: nil)
        }
        let surfaceSelection = reading.requestedSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }

        let resolved = reading.resolveTarget(
            params: params,
            requestedWorkspaceID: workspaceSelection.workspaceID,
            preferredSurfaceID: surfaceSelection.surfaceID
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
                "session_id": .string(sessionID),
                "attachment_id": .string(attachmentID),
            ]))
        }

        do {
            try controller.resizePTY(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken,
                cols: cols,
                rows: rows
            )
            var payload = Self.targetPayload(target)
            payload["session_id"] = .string(sessionID)
            payload["attachment_id"] = .string(attachmentID)
            payload["attachment_token"] = .string(attachmentToken)
            payload["cols"] = .int(Int64(cols))
            payload["rows"] = .int(Int64(rows))
            payload["resized"] = .bool(true)
            return .ok(.object(payload))
        } catch {
            return .err(code: "remote_pty_error", message: Self.userFacingErrorMessage(error), data: .object([
                "workspace_id": .string(target.workspaceID.uuidString),
                "workspace_ref": target.workspaceRef,
                "session_id": .string(sessionID),
                "attachment_id": .string(attachmentID),
            ]))
        }
    }

    // MARK: - Payload shaping (the former v2RemotePTYTargetPayload / v2RemotePTYSessionPayload)

    /// The shared per-target reply keys (the former `v2RemotePTYTargetPayload`):
    /// `window_id` (the workspace's window UUID or `null`), `window_ref`,
    /// `workspace_id`, `workspace_ref`, `workspace_title`.
    static func targetPayload(_ target: ControlRemotePTYTarget) -> [String: JSONValue] {
        [
            "window_id": target.windowID.map { JSONValue.string($0.uuidString) } ?? .null,
            "window_ref": target.windowRef,
            "workspace_id": .string(target.workspaceID.uuidString),
            "workspace_ref": target.workspaceRef,
            "workspace_title": .string(target.workspaceTitle),
        ]
    }

    /// Merges the per-target reply keys into one session's wire dictionary (the
    /// former `v2RemotePTYSessionPayload`): the daemon's session object plus
    /// `window_id` / `window_ref` / `workspace_id` / `workspace_ref` /
    /// `workspace_title`. A non-object session value is returned unchanged (the
    /// legacy code only ever received daemon session objects).
    static func sessionPayload(_ session: JSONValue, target: ControlRemotePTYTarget) -> JSONValue {
        guard case .object(var payload) = session else { return session }
        payload["window_id"] = target.windowID.map { JSONValue.string($0.uuidString) } ?? .null
        payload["window_ref"] = target.windowRef
        payload["workspace_id"] = .string(target.workspaceID.uuidString)
        payload["workspace_ref"] = target.workspaceRef
        payload["workspace_title"] = .string(target.workspaceTitle)
        return .object(payload)
    }

    // MARK: - User-facing error rendering (the former v2RemotePTYUserFacingErrorMessage)

    /// Maps a thrown error to the user-facing `remote_pty_error` message, the
    /// byte-faithful twin of the legacy `v2RemotePTYUserFacingErrorMessage(_:)`
    /// (which read `error.localizedDescription`).
    static func userFacingErrorMessage(_ error: any Error) -> String {
        userFacingErrorMessage(error.localizedDescription)
    }

    /// The string-form classifier behind ``userFacingErrorMessage(_:)-(Error)``,
    /// the byte-faithful twin of the legacy
    /// `v2RemotePTYUserFacingErrorMessage(_ message: String)`.
    static func userFacingErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "remote PTY operation failed" }
        let lowered = trimmed.lowercased()
        if lowered.contains("missing required capability") ||
            lowered.contains("pty.session") ||
            lowered.contains("method_not_found") {
            return "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
        }
        if lowered.contains("pty_session_not_found") ||
            (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
            (lowered.contains("persistent pty session") && lowered.contains("not running")) {
            return "persistent SSH PTY session is no longer running"
        }
        if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
            return "remote PTY input is temporarily backed up"
        }
        if lowered.contains("remote connection is not active") {
            return "remote connection is not active"
        }
        if lowered.contains("remote daemon is not ready") || lowered.contains("remote daemon tunnel is not ready") {
            return "remote daemon is not ready"
        }
        if lowered.contains("missing workspace_id in ssh pty session list response") {
            return "missing workspace_id in SSH PTY session list response"
        }
        if lowered.contains("missing session_id in ssh pty session list response") {
            return "missing session_id in SSH PTY session list response"
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return "remote daemon did not respond in time"
        }
        return "remote PTY operation failed"
    }

    // MARK: - Param parsing (twins of the app's v2Bool / v2RawString / v2StrictInt / v2HasNonNullParam)

    /// Whether `key` is present and not JSON `null` (the former `v2HasNonNullParam`).
    static func hasNonNullParam(_ params: [String: JSONValue], _ key: String) -> Bool {
        guard let raw = params[key] else { return false }
        if case .null = raw { return false }
        return true
    }

    /// Coerces `key` to `Bool`, matching the former `v2Bool`: a JSON boolean, a
    /// numeric (`NSNumber.boolValue`), or a string token (`1/true/yes/on` →
    /// `true`, `0/false/no/off` → `false`); otherwise `nil`. The numeric branch
    /// reads through `NSNumber` exactly as the legacy `params[key] as? NSNumber`.
    static func bool(_ params: [String: JSONValue], _ key: String) -> Bool? {
        switch params[key] {
        case .bool(let value):
            return value
        case .int(let value):
            return NSNumber(value: value).boolValue
        case .double(let value):
            return NSNumber(value: value).boolValue
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Returns `key` as a raw string trimmed of surrounding whitespace, matching
    /// the former `v2RawString(...)?.trimmingCharacters(in:)`. A non-string value
    /// is `nil` (the legacy `params[key] as? String`).
    static func trimmedRawString(_ params: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let value) = params[key] else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Coerces `key` to a strict integer, matching the former `v2StrictInt` /
    /// `v2StrictIntAny`: a JSON integer; a finite whole JSON double; a parseable
    /// trimmed string; a JSON boolean is rejected. The double/boolean handling
    /// mirrors the legacy `NSNumber`/`CFBooleanGetTypeID` path exactly.
    static func strictInt(_ params: [String: JSONValue], _ key: String) -> Int? {
        switch params[key] {
        case .int(let value):
            return Int(exactly: value)
        case .double(let value):
            guard value.isFinite, floor(value) == value else { return nil }
            return Int(exactly: value)
        case .bool:
            return nil
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
