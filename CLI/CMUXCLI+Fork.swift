import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    var forkCommandUsageLine: String {
        String(
            localized: "cli.help.fork",
            defaultValue: "fork [--surface <id|ref>] <kind> <checkpoint-id> | fork --surface [id|ref]"
        )
    }

    /// Full help text for `cmux fork`, kept with the verb implementation.
    func forkSubcommandUsage() -> String {
        String(localized: "cli.fork.help", defaultValue: """
        Usage: cmux fork [--surface <id|ref>] <kind> <checkpoint-id>
               cmux fork <kind> <checkpoint-id> --surface <id|ref>
               cmux fork --surface=<id|ref> <kind> <checkpoint-id>
               cmux fork --surface [id|ref]

        Replace this CLI process with the provider's fork launch from the
        persisted surface record. New records preserve fork arguments and
        cwd as structured values; command-only records use a compatibility shell.
        With no id or ref, --surface uses the calling cmux surface.
        """)
    }

    /// Resolves a surface restore record and replaces this CLI process with the
    /// provider-specific fork launch.
    func runForkCommand(
        commandArgs: [String],
        client: SocketClient,
        processEnvironment: [String: String]
    ) throws {
        let selector = try continuationSelector(commandArgs, verb: .fork)
        let workingDirectoryBeforeFork = FileManager.default.currentDirectoryPath
        let surfaceID = try continuationSurfaceID(
            for: selector,
            client: client,
            processEnvironment: processEnvironment,
            verb: .fork
        )
        let params: [String: Any] = ["surface_id": surfaceID]
        let payload = try client.sendV2(method: "surface.resume.get", params: params)
        guard let rawRecord = payload["restore_record"] as? [String: Any] else {
            throw loggedForkError(
                .noRecord,
                stage: "record.missing"
            )
        }
        var record = try restoreRecord(from: rawRecord, verb: .fork)
        if let expectedKind = selector.kind, expectedKind != record.kind {
            throw loggedForkError(
                .kindMismatch,
                stage: "record.kind-mismatch",
                detail: "expected=\(expectedKind) actual=\(record.kind)"
            )
        }
        if let expectedCheckpointID = selector.checkpointID,
           expectedCheckpointID != record.checkpointID {
            throw loggedForkError(
                .checkpointMismatch,
                stage: "record.checkpoint-mismatch",
                detail: "expected=\(expectedCheckpointID) actual=\(record.checkpointID ?? "none")"
            )
        }

        guard let recordMode = AgentRestoreRequestMode(rawValue: record.mode),
              recordMode != .relaunchAgent else {
            throw loggedForkError(
                .unsupportedMode,
                stage: "record.mode",
                detail: record.mode
            )
        }

        record = try recoveredForkRestoreRecord(
            record,
            surfaceID: surfaceID,
            processEnvironment: processEnvironment
        )

        let bindingPayload = payload["resume_binding"] as? [String: Any]
        if let codexValidation = codexRestoreValidation(
            record: record,
            bindingPayload: bindingPayload,
            processEnvironment: processEnvironment
        ) {
            switch codexValidation {
            case .allowed:
                break
            case .missing, .unavailable, .rejectedChild, .bindingChanged:
                try handleRejectedCodexFork(
                    codexValidation,
                    record: record,
                    bindingPayload: bindingPayload,
                    surfaceID: surfaceID,
                    workspaceID: payload["workspace_id"] as? String
                        ?? processEnvironment["CMUX_WORKSPACE_ID"],
                    client: client,
                    workingDirectoryBeforeFork: workingDirectoryBeforeFork
                )
                return
            }
        }

        if codexRestoreBindingRequiresClaim(record),
           record.forkArguments == nil,
           legacyForkCommand(for: record) != nil,
           !claimCodexRestoreBinding(
               record: record,
               bindingPayload: bindingPayload,
               surfaceID: surfaceID,
               client: client
           ) {
            try handleRejectedCodexFork(
                .bindingChanged,
                record: record,
                bindingPayload: bindingPayload,
                surfaceID: surfaceID,
                workspaceID: payload["workspace_id"] as? String
                    ?? processEnvironment["CMUX_WORKSPACE_ID"],
                client: client,
                workingDirectoryBeforeFork: workingDirectoryBeforeFork
            )
            return
        }

        let legacyCommand = legacyForkCommand(for: record)
        let environment = processEnvironment.merging(record.environment) { _, restored in
            restored
        }
        if record.forkArguments == nil,
           let legacyCommand {
            try execLegacyForkRecord(
                legacyCommand,
                record: record,
                environment: environment,
                client: client
            )
        }

        let requestedWorkingDirectory = requestedRestoreWorkingDirectory(for: record)
        let appliedWorkingDirectory = try applyForkWorkingDirectory(requestedWorkingDirectory)
        let effectiveWorkingDirectory: String? =
            if requestedWorkingDirectory?.isEmpty == false {
                appliedWorkingDirectory ?? FileManager.default.currentDirectoryPath
            } else {
                nil
            }
        let request = AgentRestoreRequest(
            mode: .forkAgent,
            kind: record.kind,
            checkpointID: record.checkpointID,
            source: record.source,
            workingDirectory: effectiveWorkingDirectory,
            environment: record.environment,
            launchCommand: record.launchCommand,
            preparedArguments: record.forkArguments,
            preparedArgumentsWorkingDirectory: normalizedRestoreWorkingDirectory(
                record.forkArgumentsWorkingDirectory
            ),
            observedPermissionMode: record.permissionMode
        )
        guard let invocation = AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: request,
            ambientEnvironment: processEnvironment
        ) else {
            if let legacyCommand {
                try execLegacyForkRecord(
                    legacyCommand,
                    record: record,
                    environment: environment,
                    client: client
                )
            }
            if !recordCanBuildFork(record),
               legacyCommand == nil {
                throw loggedForkError(
                    .unsupported,
                    stage: "record.fork-unsupported",
                    detail: record.kind
                )
            }
            throw loggedForkError(
                .incompleteData,
                stage: "record.incomplete",
                detail: "mode=\(record.mode) kind=\(record.kind)"
            )
        }

        for preflight in invocation.preflightInvocations {
            do {
                try runRestorePreflight(
                    preflight,
                    appliedWorkingDirectory: effectiveWorkingDirectory
                )
            } catch {
                throw loggedForkError(
                    .providerSetupFailed,
                    stage: "provider.preflight",
                    detail: String(reflecting: type(of: error))
                )
            }
        }
        if codexRestoreBindingRequiresClaim(record),
           !claimCodexRestoreBinding(
               record: record,
               bindingPayload: bindingPayload,
               surfaceID: surfaceID,
               client: client
           ) {
            try handleRejectedCodexFork(
                .bindingChanged,
                record: record,
                bindingPayload: bindingPayload,
                surfaceID: surfaceID,
                workspaceID: payload["workspace_id"] as? String
                    ?? processEnvironment["CMUX_WORKSPACE_ID"],
                client: client,
                workingDirectoryBeforeFork: workingDirectoryBeforeFork
            )
            return
        }
        client.close()
        try execForkInvocation(
            invocation,
            appliedWorkingDirectory: effectiveWorkingDirectory
        )
    }

    private func recoveredForkRestoreRecord(
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
            throw loggedForkError(
                .noRecord,
                stage: "hermes.checkpoint.missing",
                detail: checkpointID
            )
        case .recovered(let candidate):
            return record.repairingHermesCheckpoint(
                candidate.sessionID,
                fallbackLaunchCommand: candidate.launchCommand
            )
        }
    }

    private func legacyForkCommand(for record: RestoreRecord) -> String? {
        if let explicit = record.legacyForkCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        guard let legacy = record.legacyCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !legacy.isEmpty else {
            return nil
        }
        if record.mode == AgentRestoreRequestMode.forkAgent.rawValue {
            return legacy
        }
        // Older command-only records had no separate fork field. Reuse one only
        // when its command explicitly carries a fork switch, never a plain resume.
        guard legacy.contains("--fork") || legacy.contains("--fork-session") else {
            return nil
        }
        return legacy
    }

}
