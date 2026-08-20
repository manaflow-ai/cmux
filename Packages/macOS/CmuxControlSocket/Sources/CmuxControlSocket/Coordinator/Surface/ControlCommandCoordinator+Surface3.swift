internal import Foundation

/// The surface-domain resume (`surface.resume.*`) and reporting
/// (`surface.report_tty` / `report_pwd` / `report_shell_state` / `ports_kick`)
/// bodies, plus the shared resume-binding payload helper, split out of
/// `ControlCommandCoordinator+Surface.swift` to keep each file under the 500-line
/// budget. See that file's doc comment for the domain overview.
extension ControlCommandCoordinator {

    // MARK: - resume target param validation

    /// The byte-faithful twin of `v2SurfaceResumeTargetValidationError`: an
    /// `invalid_params` error when any of `window_id` / `workspace_id` /
    /// `surface_id` / `terminal_id` / `tab_id` is present-but-non-null yet
    /// does not resolve.
    private func surfaceResumeTargetValidationError(
        _ params: [String: JSONValue]
    ) -> ControlCallResult? {
        for key in ["window_id", "workspace_id", "surface_id", "terminal_id", "tab_id"] where hasNonNull(params, key) {
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
        let remoteWorkspaceID = uuid(params, "_cmux_remote_workspace_id")
        if hasNonNull(params, "_cmux_remote_workspace_id"), remoteWorkspaceID == nil {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.surfaceSplitOff.error.invalidWorkspaceId",
                    defaultValue: "Missing or invalid workspace_id"
                ),
                data: nil
            )
        }
        let launchCommand: ControlAgentLaunchCommand?
        switch params["launch_command"] {
        case nil, .null:
            launchCommand = nil
        case let value?:
            guard let parsed = controlAgentLaunchCommand(value) else {
                return .err(
                    code: "invalid_params",
                    message: surfaceResumeStrings().launchCommandMustBeValid,
                    data: nil
                )
            }
            launchCommand = parsed
        }
        let inputs = ControlSurfaceResumeSetInputs(
            name: optionalTrimmedRawString(params, "name"),
            kind: optionalTrimmedRawString(params, "kind"),
            command: command,
            cwd: optionalTrimmedRawString(params, "cwd"),
            checkpointID: optionalTrimmedRawString(params, "checkpoint_id")
                ?? optionalTrimmedRawString(params, "checkpointId"),
            source: source,
            environment: stringMap(params, "environment"),
            launchCommand: launchCommand,
            permissionMode: optionalTrimmedRawString(params, "permission_mode"),
            autoResume: source == "agent-hook" ? (bool(params, "auto_resume") ?? false) : false,
            remoteWorkspaceID: remoteWorkspaceID,
            remoteRelayParameters: remoteWorkspaceID == nil ? nil : params,
            resumeEvidenceProvenance: optionalTrimmedRawString(params, "resume_evidence_provenance")
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

    /// The explicit resume-target selector. `terminal_id` is accepted as the
    /// public terminal alias for `surface_id`, matching general socket routing.
    private func surfaceResumeExplicitTargetID(_ params: [String: JSONValue]) -> UUID? {
        uuid(params, "surface_id") ?? uuid(params, "terminal_id") ?? uuid(params, "tab_id")
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
        let agentSessionEnded: Bool
        switch params["agent_session_ended"] {
        case .none:
            agentSessionEnded = false
        case .some(.bool(let value)):
            agentSessionEnded = value
        case .some:
            return .err(
                code: "invalid_params",
                message: surfaceResumeStrings().agentSessionEndedMustBeBoolean,
                data: nil
            )
        }
        let resolution = context?.controlSurfaceResumeClear(
            routing: routing,
            explicitTargetID: surfaceResumeExplicitTargetID(params),
            hasResolvedWindowID: uuid(params, "window_id") != nil,
            expectedCheckpointID: optionalTrimmedRawString(params, "checkpoint_id")
                ?? optionalTrimmedRawString(params, "checkpointId"),
            expectedSource: optionalTrimmedRawString(params, "source"),
            agentSessionEnded: agentSessionEnded
        ) ?? .surfaceNotFound
        return surfaceResumeResult(resolution)
    }

    /// The localized surface-resume strings supplied by the app bundle.
    private func surfaceResumeStrings() -> ControlSurfaceResumeStrings {
        context?.controlSurfaceResumeStrings() ?? ControlSurfaceResumeStrings(
            agentSessionEndedMustBeBoolean: "",
            launchCommandMustBeValid: ""
        )
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
        case .approvalPending(let message):
            return .err(
                code: "busy",
                message: message,
                data: .object(["retryable": .bool(true)])
            )
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
                "restore_record": surfaceRestoreRecordPayload(snapshot.restoreRecord),
            ]))
        }
    }

    /// The byte-faithful twin of `v2SurfaceResumeBindingPayload`: a `null` binding
    /// becomes JSON `null`, else the resume-binding object. Shared by `surface.list`
    /// rows and the resume results. `nonisolated`: pure value mapping, used by
    /// the worker-lane `surface.list` body's off-main payload shaping.
    nonisolated func surfaceResumeBindingPayload(_ binding: ControlSurfaceResumeBinding?) -> JSONValue {
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
            "launch_command": controlAgentLaunchCommandPayload(binding.launchCommand),
            "permission_mode": orNull(binding.permissionMode),
            "auto_resume": .bool(binding.autoResume),
            "resume_evidence_provenance": orNull(binding.resumeEvidenceProvenance),
            "approval_policy": orNull(binding.approvalPolicyRawValue),
            "approval_record_id": orNull(binding.approvalRecordID),
            "execution_location": .string(binding.executionLocationRawValue),
            "remote_workspace_id": orNull(binding.remoteWorkspaceID?.uuidString),
            "remote_surface_id": orNull(binding.remoteSurfaceID?.uuidString),
            "remote_pty_session_id": orNull(binding.remotePTYSessionID),
            "updated_at": .double(binding.updatedAt),
        ])
    }

    private func controlAgentLaunchCommand(_ value: JSONValue?) -> ControlAgentLaunchCommand? {
        guard case .object(let object)? = value,
              case .array(let rawArguments)? = object["arguments"] else {
            return nil
        }
        for key in [
            "launcher",
            "external_launcher",
            "executable_path",
            "working_directory",
            "verification_home",
            "source",
        ] {
            switch object[key] {
            case nil, .null, .string:
                break
            default:
                return nil
            }
        }
        switch object["environment"] {
        case nil, .null:
            break
        case .object(let environment):
            guard environment.values.allSatisfy({
                if case .string = $0 { return true }
                return false
            }) else {
                return nil
            }
        default:
            return nil
        }
        switch object["captured_at"] {
        case nil, .null, .double, .int:
            break
        default:
            return nil
        }
        let arguments = rawArguments.compactMap { value -> String? in
            guard case .string(let argument) = value else { return nil }
            return argument
        }
        guard arguments.count == rawArguments.count, !arguments.isEmpty else { return nil }
        return ControlAgentLaunchCommand(
            launcher: rawString(object, "launcher"),
            // Trimmed on the way in: the id is compared against `agents.launchers` declarations,
            // which are normalized, so a padded value would silently resolve to nothing.
            externalLauncher: optionalTrimmedRawString(object, "external_launcher"),
            executablePath: rawString(object, "executable_path"),
            arguments: arguments,
            workingDirectory: rawString(object, "working_directory"),
            environment: stringMap(object, "environment"),
            verificationHome: rawString(object, "verification_home"),
            capturedAt: doubleValue(object["captured_at"]),
            source: rawString(object, "source")
        )
    }

    private nonisolated func controlAgentLaunchCommandPayload(
        _ command: ControlAgentLaunchCommand?
    ) -> JSONValue {
        guard let command else { return .null }
        let environment = command.environment.map {
            JSONValue.object($0.mapValues(JSONValue.string))
        } ?? .null
        return .object([
            "launcher": orNull(command.launcher),
            "external_launcher": orNull(command.externalLauncher),
            "executable_path": orNull(command.executablePath),
            "arguments": .array(command.arguments.map(JSONValue.string)),
            "working_directory": orNull(command.workingDirectory),
            "environment": environment,
            "verification_home": orNull(command.verificationHome),
            "captured_at": command.capturedAt.map(JSONValue.double) ?? .null,
            "source": orNull(command.source),
        ])
    }

    private nonisolated func surfaceRestoreRecordPayload(
        _ record: ControlSurfaceRestoreRecord?
    ) -> JSONValue {
        guard let record else { return .null }
        return .object([
            "mode": .string(record.modeRawValue),
            "kind": .string(record.kind),
            "checkpoint_id": orNull(record.checkpointID),
            "source": orNull(record.source),
            "working_directory": orNull(record.workingDirectory),
            "environment": .object(record.environment.mapValues(JSONValue.string)),
            "launch_command": controlAgentLaunchCommandPayload(record.launchCommand),
            "prepared_arguments": record.preparedArguments.map {
                .array($0.map(JSONValue.string))
            } ?? .null,
            "prepared_arguments_working_directory": orNull(
                record.preparedArgumentsWorkingDirectory
            ),
            "permission_mode": orNull(record.permissionMode),
            "legacy_command": orNull(record.legacyCommand),
        ])
    }

    private func doubleValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let value): value
        case .int(let value): Double(value)
        case .decimal(let value): NSDecimalNumber(string: value).doubleValue
        default: nil
        }
    }

    // MARK: - report_pwd

    /// `surface.report_pwd` — record a surface's current working directory.
    func surfaceReportPWD(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceID = uuid(params, "surface_id")
        if hasNonNull(params, "surface_id"), requestedSurfaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        // Accept compatibility aliases, but require one exact cwd value.
        let candidatePaths = ["path", "directory", "cwd"]
            .compactMap { rawString(params, $0) }
            .filter { $0.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil }
        guard let path = candidatePaths.first else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }
        guard candidatePaths.allSatisfy({ $0 == path }) else {
            return .err(code: "invalid_params", message: "Conflicting path parameters", data: nil)
        }

        let resolution = context?.controlSurfaceReportPWD(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID,
            path: path
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
            payload["path"] = .string(path)
            payload["pending"] = .bool(true)
            return .ok(.object(payload))
        case .recorded(let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "path": .string(path),
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
        let terminalLifecycleID = uuid(params, "terminal_lifecycle_id")
        if hasNonNull(params, "terminal_lifecycle_id"), terminalLifecycleID == nil {
            return .err(
                code: "invalid_params",
                message: context?
                    .controlSurfaceInvalidTerminalLifecycleIDError()
                    ?? "Terminal session is out of date; restart the shell and try again",
                data: nil
            )
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
            terminalLifecycleID: terminalLifecycleID,
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
    func surfaceReportSurfaceFields(
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
