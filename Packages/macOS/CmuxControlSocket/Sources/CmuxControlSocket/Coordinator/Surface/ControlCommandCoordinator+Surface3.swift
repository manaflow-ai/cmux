internal import Foundation

/// The surface-domain resume (`surface.resume.*`) and reporting
/// (`surface.report_tty` / `report_shell_state` / `ports_kick`) bodies, plus the
/// shared resume-binding payload helper, split out of
/// `ControlCommandCoordinator+Surface.swift` to keep each file under the 500-line
/// budget. See that file's doc comment for the domain overview.
extension ControlCommandCoordinator {

    // MARK: - resume target param validation

    /// The byte-faithful twin of `v2SurfaceResumeTargetValidationError`: an
    /// `invalid_params` error when any of `window_id` / `workspace_id` /
    /// `surface_id` / `tab_id` is present-but-non-null yet does not resolve.
    private func surfaceResumeTargetValidationError(
        _ params: [String: JSONValue]
    ) -> ControlCallResult? {
        for key in ["window_id", "workspace_id", "surface_id", "tab_id"] where hasNonNull(params, key) {
            if uuid(params, key) == nil {
                return .err(code: "invalid_params", message: "Missing or invalid \(key)", data: nil)
            }
        }
        return nil
    }

    /// The legacy `v2PublicSurfaceResumeSource`: `process-detected` → `manual`.
    private func publicResumeSource(_ params: [String: JSONValue]) -> String? {
        let source = optionalTrimmedRawString(params, "source")
        return source == "process-detected" ? "manual" : source
    }

    // MARK: - resume.set

    /// `surface.resume.set` — set (and run the approval flow for) a resume binding.
    func surfaceResumeSet(_ params: [String: JSONValue]) -> ControlCallResult {
        if let error = surfaceResumeTargetValidationError(params) { return error }
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: Self.surfaceWindowUnavailableMessage, data: nil)
        }
        guard let command = rawString(params, "command")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !command.isEmpty else {
            return .err(code: "invalid_params", message: "Missing command", data: nil)
        }

        let source = publicResumeSource(params)
        let inputs = ControlSurfaceResumeSetInputs(
            name: optionalTrimmedRawString(params, "name"),
            kind: optionalTrimmedRawString(params, "kind"),
            command: command,
            cwd: optionalTrimmedRawString(params, "cwd"),
            checkpointID: optionalTrimmedRawString(params, "checkpoint_id")
                ?? optionalTrimmedRawString(params, "checkpointId"),
            source: source,
            environment: stringMap(params, "environment"),
            autoResume: source == "agent-hook" ? (bool(params, "auto_resume") ?? false) : false
        )
        return surfaceResumeResult(
            context?.controlSurfaceResumeSet(
                routing: routing,
                explicitTargetID: surfaceResumeExplicitTargetID(params),
                hasResolvedWindowID: uuid(params, "window_id") != nil,
                inputs: inputs
            ) ?? .setFailed
        )
    }

    /// The legacy resume-target selector: `surface_id ?? tab_id` ONLY — the
    /// `terminal_id` alias that general routing honors was never part of the
    /// resume-target precedence (origin `v2ResolveSurfaceResumeTarget`).
    private func surfaceResumeExplicitTargetID(_ params: [String: JSONValue]) -> UUID? {
        uuid(params, "surface_id") ?? uuid(params, "tab_id")
    }

    // MARK: - resume.get

    /// `surface.resume.get` — read a surface's resume binding.
    func surfaceResumeGet(_ params: [String: JSONValue]) -> ControlCallResult {
        if let error = surfaceResumeTargetValidationError(params) { return error }
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: Self.surfaceWindowUnavailableMessage, data: nil)
        }
        return surfaceResumeResult(
            context?.controlSurfaceResumeGet(
                routing: routing,
                explicitTargetID: surfaceResumeExplicitTargetID(params),
                hasResolvedWindowID: uuid(params, "window_id") != nil
            ) ?? .surfaceNotFound
        )
    }

    // MARK: - resume.clear

    /// `surface.resume.clear` — clear a surface's resume binding.
    func surfaceResumeClear(_ params: [String: JSONValue]) -> ControlCallResult {
        if let error = surfaceResumeTargetValidationError(params) { return error }
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: Self.surfaceWindowUnavailableMessage, data: nil)
        }
        let resolution = context?.controlSurfaceResumeClear(
            routing: routing,
            explicitTargetID: surfaceResumeExplicitTargetID(params),
            hasResolvedWindowID: uuid(params, "window_id") != nil,
            expectedCheckpointID: optionalTrimmedRawString(params, "checkpoint_id")
                ?? optionalTrimmedRawString(params, "checkpointId"),
            expectedSource: optionalTrimmedRawString(params, "source")
        ) ?? .surfaceNotFound
        return surfaceResumeResult(resolution)
    }

    /// Shapes the shared `surface.resume.*` result.
    private func surfaceResumeResult(_ resolution: ControlSurfaceResumeResolution) -> ControlCallResult {
        switch resolution {
        case .windowUnavailable:
            // The coordinator already guards `unavailable` before calling the seam;
            // this mirrors the legacy fallback for completeness.
            return .err(code: "unavailable", message: Self.surfaceWindowUnavailableMessage, data: nil)
        case .surfaceNotFound:
            return .err(code: "not_found", message: "Surface not found", data: nil)
        case .emptyResumeCommand:
            return .err(code: "invalid_params", message: "Resume command is empty", data: nil)
        case .setFailed:
            return .err(code: "internal_error", message: "Failed to set resume binding", data: nil)
        case .result(let snapshot):
            return .ok(.object([
                "window_id": orNull(snapshot.windowID?.uuidString),
                "window_ref": ref(.window, snapshot.windowID),
                "workspace_id": .string(snapshot.workspaceID.uuidString),
                "workspace_ref": ref(.workspace, snapshot.workspaceID),
                "pane_id": orNull(snapshot.paneID?.uuidString),
                "pane_ref": ref(.pane, snapshot.paneID),
                "surface_id": .string(snapshot.surfaceID.uuidString),
                "surface_ref": ref(.surface, snapshot.surfaceID),
                "cleared": .bool(snapshot.cleared),
                "resume_binding": surfaceResumeBindingPayload(snapshot.binding),
            ]))
        }
    }

    /// The byte-faithful twin of `v2SurfaceResumeBindingPayload`: a `null` binding
    /// becomes JSON `null`, else the resume-binding object. Shared by `surface.list`
    /// rows and the resume results.
    func surfaceResumeBindingPayload(_ binding: ControlSurfaceResumeBinding?) -> JSONValue {
        guard let binding else { return .null }
        let environment: JSONValue = binding.environment.map { env in
            .object(env.mapValues { .string($0) })
        } ?? .null
        return .object([
            "name": orNull(binding.name),
            "kind": orNull(binding.kind),
            "command": .string(binding.command),
            "cwd": orNull(binding.cwd),
            "checkpoint_id": orNull(binding.checkpointID),
            "source": orNull(binding.source),
            "environment": environment,
            "auto_resume": .bool(binding.autoResume),
            "approval_policy": orNull(binding.approvalPolicyRawValue),
            "approval_record_id": orNull(binding.approvalRecordID),
            "updated_at": .double(binding.updatedAt),
        ])
    }

    // MARK: - report_tty

    /// `surface.report_tty` — record a reported TTY name.
    func surfaceReportTTY(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceID = uuid(params, "surface_id")
        if hasNonNull(params, "surface_id"), requestedSurfaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let ttyName = rawString(params, "tty_name")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty else {
            return .err(code: "invalid_params", message: "Missing tty_name", data: nil)
        }

        let resolution = context?.controlSurfaceReportTTY(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID,
            ttyName: ttyName
        ) ?? .workspaceNotFound
        let requestedSurfaceData = surfaceReportSurfaceFields(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID
        )
        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object(requestedSurfaceData))
        case .surfaceNotFound:
            return .err(code: "not_found", message: "Surface not found", data: .object(requestedSurfaceData))
        case .pending:
            var payload = requestedSurfaceData
            payload["tty_name"] = .string(ttyName)
            payload["pending"] = .bool(true)
            return .ok(.object(payload))
        case .recorded(let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "tty_name": .string(ttyName),
            ]))
        }
    }

    // MARK: - report_shell_state

    /// `surface.report_shell_state` — record reported shell-activity state.
    func surfaceReportShellState(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceID = uuid(params, "surface_id")
        if hasNonNull(params, "surface_id"), requestedSurfaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let rawState = rawString(params, "state")
            ?? rawString(params, "shell_state")
            ?? rawString(params, "activity")
        guard let rawState,
              let stateRawValue = context?.controlSurfaceParseShellActivityState(rawState) else {
            return .err(code: "invalid_params", message: "state must be prompt, running, or unknown", data: nil)
        }

        let resolution = context?.controlSurfaceReportShellState(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID,
            stateRawValue: stateRawValue
        ) ?? .pending
        switch resolution {
        case .explicit(let surfaceID, let published):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "state": .string(stateRawValue),
                "published": .bool(published),
            ]))
        case .pending:
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .null,
                "surface_ref": .null,
                "state": .string(stateRawValue),
                "published": .bool(true),
                "pending": .bool(true),
            ]))
        }
    }

    // MARK: - ports_kick

    /// `surface.ports_kick` — kick the port scanner for a surface.
    func surfacePortsKick(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceID = uuid(params, "surface_id")
        if hasNonNull(params, "surface_id"), requestedSurfaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let reasonRawValue: String
        if let rawReason = rawString(params, "reason") {
            guard let parsed = context?.controlSurfaceParsePortScanKickReason(rawReason) else {
                return .err(code: "invalid_params", message: "reason must be command or refresh", data: nil)
            }
            reasonRawValue = parsed
        } else {
            reasonRawValue = "command"
        }

        let resolution = context?.controlSurfacePortsKick(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID,
            reasonRawValue: reasonRawValue
        ) ?? .workspaceNotFound
        let requestedSurfaceData = surfaceReportSurfaceFields(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID
        )
        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object(requestedSurfaceData))
        case .surfaceNotFound:
            return .err(code: "not_found", message: "Surface not found", data: .object(requestedSurfaceData))
        case .pending:
            var payload = requestedSurfaceData
            payload["reason"] = .string(reasonRawValue)
            payload["pending"] = .bool(true)
            return .ok(.object(payload))
        case .kicked(let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "reason": .string(reasonRawValue),
            ]))
        }
    }

    /// The shared workspace/requested-surface field block the report/kick payloads
    /// echo (the legacy `v2OrNull` requested-surface shape).
    private func surfaceReportSurfaceFields(
        workspaceID: UUID,
        requestedSurfaceID: UUID?
    ) -> [String: JSONValue] {
        [
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": ref(.workspace, workspaceID),
            "surface_id": orNull(requestedSurfaceID?.uuidString),
            "surface_ref": ref(.surface, requestedSurfaceID),
        ]
    }
}
