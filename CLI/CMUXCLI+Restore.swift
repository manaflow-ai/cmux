import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    var restoreCommandUsageLine: String {
        String(
            localized: "cli.help.restore",
            defaultValue: "restore [--surface <id|ref>] [--cwd <path>] <kind> <checkpoint-id> | restore --surface [id|ref] [--cwd <path>]"
        )
    }

    func controlAgentLaunchCommandPayload(
        _ command: AgentLaunchCommand
    ) -> [String: Any] {
        var payload: [String: Any] = ["arguments": command.arguments]
        if let launcher = command.launcher {
            payload["launcher"] = launcher
        }
        if let executablePath = command.executablePath {
            payload["executable_path"] = executablePath
        }
        if let workingDirectory = command.workingDirectory {
            payload["working_directory"] = workingDirectory
        }
        if let environment = command.environment {
            payload["environment"] = environment
        }
        if let verificationHome = command.verificationHome {
            payload["verification_home"] = verificationHome
        }
        if let capturedAt = command.capturedAt {
            payload["captured_at"] = capturedAt
        }
        if let source = command.source {
            payload["source"] = source
        }
        return payload
    }

    func runRestoreCommand(
        commandArgs: [String],
        client: SocketClient,
        processEnvironment: [String: String]
    ) throws {
        let selector = try restoreSelector(commandArgs)
        let workingDirectoryBeforeRestore = FileManager.default.currentDirectoryPath
        var params: [String: Any] = [:]
        if let surface = selector.surface {
            let surfaceID = try normalizeSurfaceHandle(
                surface,
                client: client,
                workspaceHandle: nil,
                windowHandle: nil
            )
            guard let surfaceID else {
                throw loggedRestoreError(
                    stage: "surface.lookup",
                    detail: surface,
                    message: String(
                        localized: "cli.restore.error.surfaceNotFound",
                        defaultValue: "restore: the requested surface was not found. Check the surface reference, then retry."
                    )
                )
            }
            params["surface_id"] = surfaceID
        } else if selector.usesCurrentSurface,
                  let surfaceID = try currentRestoreSurfaceID(
                      client: client,
                      processEnvironment: processEnvironment
                  ) {
            params["surface_id"] = surfaceID
        } else {
            throw currentRestoreSurfaceUnknownError()
        }

        let payload = try client.sendV2(method: "surface.resume.get", params: params)
        guard let rawRecord = payload["restore_record"] as? [String: Any] else {
            throw loggedRestoreError(
                stage: "record.missing",
                message: String(
                    localized: "cli.restore.error.noRecord",
                    defaultValue: "restore: this session has nothing to restore. Start the agent again in this terminal."
                )
            )
        }
        var record = try restoreRecord(from: rawRecord)
        if let expectedKind = selector.kind, expectedKind != record.kind {
            throw loggedRestoreError(
                stage: "record.kind-mismatch",
                detail: "expected=\(expectedKind) actual=\(record.kind)",
                message: String(
                    localized: "cli.restore.error.kindMismatch",
                    defaultValue: "restore: this command no longer matches the session. Run 'cmux restore --surface' to use the current record."
                )
            )
        }
        if let expectedCheckpointID = selector.checkpointID,
           expectedCheckpointID != record.checkpointID {
            throw loggedRestoreError(
                stage: "record.checkpoint-mismatch",
                detail: "expected=\(expectedCheckpointID) actual=\(record.checkpointID ?? "none")",
                message: String(
                    localized: "cli.restore.error.checkpointMismatch",
                    defaultValue: "restore: this command no longer matches the session. Run 'cmux restore --surface' to use the current record."
                )
            )
        }

        if let surfaceID = params["surface_id"] as? String {
            record = try recoveredHermesRestoreRecord(
                record,
                surfaceID: surfaceID,
                processEnvironment: processEnvironment
            )
        }

        let bindingPayload = payload["resume_binding"] as? [String: Any]
        if let codexValidation = codexRestoreValidation(
            record: record,
            bindingPayload: bindingPayload,
            processEnvironment: processEnvironment
        ) {
            let shouldContinue: Bool
            switch codexValidation {
            case .allowed:
                shouldContinue = true
            case .missing, .unavailable, .rejectedChild, .bindingChanged:
                shouldContinue = false
            }
            if !shouldContinue {
                try handleRejectedCodexRestore(
                    codexValidation,
                    record: record,
                    bindingPayload: bindingPayload,
                    surfaceID: params["surface_id"] as? String,
                    workspaceID: payload["workspace_id"] as? String
                        ?? processEnvironment["CMUX_WORKSPACE_ID"],
                    client: client,
                    workingDirectoryBeforeRestore: workingDirectoryBeforeRestore
                )
                return
            }
        }

        // Legacy command-only records predate structured launch captures, but
        // an agent-hook Codex record still names a mutable surface owner. Claim
        // that generation before handing the shell command to exec so an
        // intervening child publication cannot steal the restore.
        if codexRestoreBindingRequiresClaim(record),
           record.launchCommand == nil,
           record.preparedArguments == nil,
           record.legacyCommand != nil,
           !claimCodexRestoreBinding(
               record: record,
               bindingPayload: bindingPayload,
               surfaceID: params["surface_id"] as? String,
               client: client
           ) {
            try handleRejectedCodexRestore(
                .bindingChanged,
                record: record,
                bindingPayload: bindingPayload,
                surfaceID: params["surface_id"] as? String,
                workspaceID: payload["workspace_id"] as? String
                    ?? processEnvironment["CMUX_WORKSPACE_ID"],
                client: client,
                workingDirectoryBeforeRestore: workingDirectoryBeforeRestore
            )
            return
        }

        let environment = processEnvironment.merging(record.environment) { _, restored in
            restored
        }
        if record.launchCommand == nil,
           record.preparedArguments == nil,
           let legacyCommand = record.legacyCommand {
            try execLegacyRestoreRecord(
                legacyCommand,
                record: record,
                workingDirectoryOverride: selector.workingDirectoryOverride,
                environment: environment,
                client: client
            )
        }

        guard let mode = AgentRestoreRequestMode(rawValue: record.mode) else {
            throw loggedRestoreError(
                stage: "record.mode",
                detail: record.mode,
                message: String(
                    localized: "cli.restore.error.unsupportedMode",
                    defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
                )
            )
        }
        let requestedWorkingDirectory = selector.workingDirectoryOverride
            ?? requestedRestoreWorkingDirectory(for: record)
        let appliedWorkingDirectory = try applyRestoreWorkingDirectory(
            requestedWorkingDirectory
        )
        let effectiveWorkingDirectory: String? =
            if requestedWorkingDirectory?.isEmpty == false {
                appliedWorkingDirectory ?? FileManager.default.currentDirectoryPath
            } else {
                nil
            }
        let request = AgentRestoreRequest(
            mode: mode,
            kind: record.kind,
            checkpointID: record.checkpointID,
            source: record.source,
            workingDirectory: effectiveWorkingDirectory,
            environment: record.environment,
            launchCommand: record.launchCommand,
            preparedArguments: record.preparedArguments,
            preparedArgumentsWorkingDirectory: normalizedRestoreWorkingDirectory(
                record.preparedArgumentsWorkingDirectory
            ),
            observedPermissionMode: record.permissionMode
        )
        guard let invocation = AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: request,
            ambientEnvironment: processEnvironment
        ) else {
            if let legacyCommand = record.legacyCommand {
                if codexRestoreBindingRequiresClaim(record),
                   !claimCodexRestoreBinding(
                       record: record,
                       bindingPayload: bindingPayload,
                       surfaceID: params["surface_id"] as? String,
                       client: client
                   ) {
                    try handleRejectedCodexRestore(
                        .bindingChanged,
                        record: record,
                        bindingPayload: bindingPayload,
                        surfaceID: params["surface_id"] as? String,
                        workspaceID: payload["workspace_id"] as? String
                            ?? processEnvironment["CMUX_WORKSPACE_ID"],
                        client: client,
                        workingDirectoryBeforeRestore: workingDirectoryBeforeRestore
                    )
                    return
                }
                try execLegacyRestoreRecord(
                    legacyCommand,
                    record: record,
                    workingDirectoryOverride: selector.workingDirectoryOverride,
                    environment: environment,
                    client: client
                )
            }
            throw loggedRestoreError(
                stage: "record.incomplete",
                detail: "mode=\(record.mode) kind=\(record.kind)",
                message: String(
                    localized: "cli.restore.error.incompleteData",
                    defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
                )
            )
        }

        for preflight in invocation.preflightInvocations {
            try runRestorePreflight(
                preflight,
                appliedWorkingDirectory: effectiveWorkingDirectory
            )
        }
        if codexRestoreBindingRequiresClaim(record),
           !claimCodexRestoreBinding(
               record: record,
               bindingPayload: bindingPayload,
               surfaceID: params["surface_id"] as? String,
               client: client
           ) {
            try handleRejectedCodexRestore(
                .bindingChanged,
                record: record,
                bindingPayload: bindingPayload,
                surfaceID: params["surface_id"] as? String,
                workspaceID: payload["workspace_id"] as? String
                    ?? processEnvironment["CMUX_WORKSPACE_ID"],
                client: client,
                workingDirectoryBeforeRestore: workingDirectoryBeforeRestore
            )
            return
        }
        client.close()
        try execRestoreInvocation(
            invocation,
            appliedWorkingDirectory: effectiveWorkingDirectory
        )
    }

    /// Repairs transient Hermes TUI identities using hook process-generation
    /// evidence and the durable Hermes state database.
    private func recoveredHermesRestoreRecord(
        _ record: RestoreRecord,
        surfaceID: String,
        processEnvironment: [String: String]
    ) throws -> RestoreRecord {
        guard record.kind == "hermes-agent",
              let checkpointID = record.checkpointID,
              let surfaceUUID = UUID(uuidString: surfaceID) else {
            return record
        }
        var recoveryEnvironment = processEnvironment
        recoveryEnvironment.merge(record.environment) { _, restored in restored }
        if let captured = record.launchCommand?.environment {
            recoveryEnvironment.merge(captured) { _, restored in restored }
        }
        let hookStatePath = agentHookStatePath(
            sessionStoreSuffix: "hermes-agent",
            env: processEnvironment
        )
        switch HermesLegacySessionIdentityRecovery().resolve(
            surfaceID: surfaceUUID,
            corruptSessionID: checkpointID,
            expectedWorkingDirectory: record.workingDirectory
                ?? record.launchCommand?.workingDirectory,
            hookStateFileURL: URL(fileURLWithPath: hookStatePath),
            environment: recoveryEnvironment
        ) {
        case .valid, .legacyRestore, .unavailable:
            return record
        case .missing:
            throw loggedRestoreError(
                stage: "hermes.checkpoint.missing",
                detail: checkpointID,
                message: String(
                    localized: "cli.restore.error.noRecord",
                    defaultValue: "restore: this session has nothing to restore. Start the agent again in this terminal."
                )
            )
        case .recovered(let candidate):
            return record.repairingHermesCheckpoint(
                candidate.sessionID,
                fallbackLaunchCommand: candidate.launchCommand
            )
        }
    }

    private func currentRestoreSurfaceID(
        client: SocketClient,
        processEnvironment: [String: String]
    ) throws -> String? {
        // The remote relay and the local CLI do not share a PID namespace.
        if client.isRelayBacked {
            return try relayRestoreSurfaceID(
                client: client,
                processEnvironment: processEnvironment
            )
        }

        do {
            let payload = try implicitCallerIdentifyResponse(
                client: client,
                processEnvironment: processEnvironment
            )
            guard let surfaceID = identifiedCallerSurfaceID(in: payload) else {
                throw currentRestoreSurfaceUnknownError()
            }
            return surfaceID
        } catch let error as CLIError {
            switch error.v2Code {
            case "not_found":
                client.close()
                throw currentRestoreSurfaceUnknownError()
            case "method_not_found", "unrecognized_method":
                // These protocol replies were consumed in full, so the socket
                // remains synchronized for the legacy discovery request.
                return legacyRestoreSurfaceID(
                    client: client,
                    workspaceID: nil
                )
            default:
                client.close()
                throw error
            }
        } catch {
            client.close()
            throw error
        }
    }

    private func relayRestoreSurfaceID(
        client: SocketClient,
        processEnvironment: [String: String]
    ) throws -> String? {
        let ttyName = resolveCallerDescriptorTTYName()
            ?? resolveCallerTTYName(includeAmbientTTY: false)
        guard let ttyName else { return nil }

        let resolution = AgentTTYBindingResolution.reportedTTY.rawValue
        let workspaceID = normalizedHandleValue(processEnvironment["CMUX_WORKSPACE_ID"])
        var params: [String: Any] = [
            "tty_name": ttyName,
            "tty_resolution": resolution,
        ]
        if let workspaceID {
            // Lets an older app identify this probe as an unsupported
            // workspace-only resolution. The authenticated relay rewrites
            // aliases and separately stamps its authoritative owner id.
            params["workspace_id"] = workspaceID
        }

        do {
            let payload = try client.sendV2(
                method: "agent.resolve_delivery_target",
                params: params
            )
            if payload["source"] as? String == "workspace",
               payload["surface_id"] == nil || payload["surface_id"] is NSNull,
               let resolvedWorkspaceID = normalizedHandleValue(payload["workspace_id"] as? String),
               isUUID(resolvedWorkspaceID) {
                // Previous app versions ignore the TTY probe and resolve
                // only workspace_id. Use their alias-rewritten result to
                // scope the legacy terminal list, not the stale remote
                // shell environment value that produced the request.
                return legacyRestoreSurfaceID(
                    client: client,
                    workspaceID: resolvedWorkspaceID
                )
            }
            guard payload["source"] as? String == "tty",
                  payload["tty_resolution"] as? String == resolution,
                  let resolvedWorkspaceID = normalizedHandleValue(payload["workspace_id"] as? String),
                  isUUID(resolvedWorkspaceID),
                  let surfaceID = normalizedHandleValue(payload["surface_id"] as? String),
                  isUUID(surfaceID) else {
                throw currentRestoreSurfaceUnknownError()
            }
            return surfaceID
        } catch let error as CLIError {
            switch error.v2Code {
            case "not_found":
                client.close()
                throw currentRestoreSurfaceUnknownError()
            case "method_not_found", "unrecognized_method":
                guard let workspaceID, isUUID(workspaceID) else { return nil }
                return legacyRestoreSurfaceID(
                    client: client,
                    workspaceID: workspaceID
                )
            default:
                client.close()
                throw error
            }
        } catch {
            client.close()
            throw error
        }
    }

    private func legacyRestoreSurfaceID(
        client: SocketClient,
        workspaceID: String?
    ) -> String? {
        // Prefer the live descriptors. Generic TTY variables can be inherited
        // across nested shells, so only dedicated cmux hints are a fallback.
        let ttyName = resolveCallerDescriptorTTYName()
            ?? resolveCallerTTYName(includeAmbientTTY: false)
        guard let ttyName,
              let binding = uniqueCallerTerminalBindingByTTY(
                  ttyName: ttyName,
                  client: client,
                  workspaceId: workspaceID
              ) else {
            return nil
        }
        return binding.surfaceId
    }

    private func currentRestoreSurfaceUnknownError() -> CLIError {
        CLIError(
            message: String(
                localized: "cli.restore.error.currentSurfaceUnknown",
                defaultValue: "restore: the current cmux surface could not be identified. Retry from this terminal or pass --surface <id|ref>."
            )
        )
    }

    private func restoreSelector(_ arguments: [String]) throws -> RestoreSelector {
        if arguments == ["--surface"] {
            return RestoreSelector(
                surface: nil,
                usesCurrentSurface: true,
                kind: nil,
                checkpointID: nil,
                workingDirectoryOverride: nil
            )
        }

        let cwdOptionCount = arguments.filter { argument in
            argument == "--cwd" || argument.hasPrefix("--cwd=")
        }.count
        guard cwdOptionCount <= 1 else {
            throw restoreUsageError()
        }
        let (workingDirectoryOverride, argumentsWithoutCwd) = parseOption(
            arguments,
            name: "--cwd"
        )
        if cwdOptionCount == 1,
           workingDirectoryOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw restoreUsageError()
        }
        if argumentsWithoutCwd == ["--surface"] {
            return RestoreSelector(
                surface: nil,
                usesCurrentSurface: true,
                kind: nil,
                checkpointID: nil,
                workingDirectoryOverride: workingDirectoryOverride
            )
        }

        let surfaceOptionCount = argumentsWithoutCwd.filter { argument in
            argument == "--surface" || argument.hasPrefix("--surface=")
        }.count
        guard surfaceOptionCount <= 1 else {
            throw CLIError(message: String(
                localized: "cli.restore.usage.surface",
                defaultValue: "Usage: cmux restore --surface [id|ref]"
            ))
        }
        let (surface, positionalArguments) = parseOption(argumentsWithoutCwd, name: "--surface")
        if surfaceOptionCount == 1 {
            guard let surface,
                  !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.restore.usage.surface",
                    defaultValue: "Usage: cmux restore --surface [id|ref]"
                ))
            }
            if positionalArguments.isEmpty {
                return RestoreSelector(
                    surface: surface,
                    usesCurrentSurface: false,
                    kind: nil,
                    checkpointID: nil,
                    workingDirectoryOverride: workingDirectoryOverride
                )
            }
        }

        guard positionalArguments.count == 2,
              !positionalArguments[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !positionalArguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw restoreUsageError()
        }
        return RestoreSelector(
            surface: surface,
            usesCurrentSurface: surface == nil,
            kind: positionalArguments[0],
            checkpointID: positionalArguments[1],
            workingDirectoryOverride: workingDirectoryOverride
        )
    }

    private func restoreUsageError() -> CLIError {
        CLIError(message: String(
            localized: "cli.restore.usage.positional",
            defaultValue: """
            Usage: cmux restore [--surface <id|ref>] [--cwd <path>] <kind> <checkpoint-id>
                   cmux restore --surface [id|ref] [--cwd <path>]
            """
        ))
    }

    private func restoreRecord(from object: [String: Any]) throws -> RestoreRecord {
        guard let mode = object["mode"] as? String,
              let kind = object["kind"] as? String else {
            throw loggedRestoreError(
                stage: "record.decode",
                detail: "keys=\(object.keys.sorted().joined(separator: ","))",
                message: String(
                    localized: "cli.restore.error.malformedRecord",
                    defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
                )
            )
        }
        let legacyCommand = object["legacy_command"] as? String
        let launchCommand: AgentLaunchCommand?
        do {
            launchCommand = try restoreLaunchCommand(from: object["launch_command"])
        } catch {
            guard legacyCommand != nil else {
                throw loggedRestoreError(
                    stage: "record.launch-command",
                    detail: String(reflecting: type(of: error)),
                    message: String(
                        localized: "cli.restore.error.malformedArguments",
                        defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
                    )
                )
            }
            launchCommand = nil
        }
        return RestoreRecord(
            mode: mode,
            kind: kind,
            checkpointID: object["checkpoint_id"] as? String,
            source: object["source"] as? String,
            workingDirectory: object["working_directory"] as? String,
            environment: object["environment"] as? [String: String] ?? [:],
            launchCommand: launchCommand,
            preparedArguments: object["prepared_arguments"] as? [String],
            preparedArgumentsWorkingDirectory:
                object["prepared_arguments_working_directory"] as? String,
            permissionMode: object["permission_mode"] as? String,
            legacyCommand: legacyCommand
        )
    }

    private func restoreLaunchCommand(from value: Any?) throws -> AgentLaunchCommand? {
        guard let object = value as? [String: Any] else { return nil }
        guard let arguments = object["arguments"] as? [String], !arguments.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.restore.error.malformedArguments",
                defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
            ))
        }
        return AgentLaunchCommand(
            launcher: object["launcher"] as? String,
            executablePath: object["executable_path"] as? String,
            arguments: arguments,
            workingDirectory: object["working_directory"] as? String,
            environment: object["environment"] as? [String: String],
            verificationHome: object["verification_home"] as? String,
            capturedAt: (object["captured_at"] as? NSNumber)?.doubleValue,
            source: object["source"] as? String
        )
    }

}
