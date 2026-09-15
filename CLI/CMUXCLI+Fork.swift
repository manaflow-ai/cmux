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

        Start a fork from the saved session on the selected surface.
        With no id or ref, --surface uses the calling cmux surface.
        """)
    }

    /// Resolves a surface restore record and replaces this CLI process with the
    /// provider-specific fork launch.
    func runForkCommand(
        commandArgs: [String],
        client: SocketClient,
        processEnvironment: [String: String]
    ) async throws {
        let selector = try continuationSelector(commandArgs, verb: .fork)
        let workingDirectoryBeforeFork = FileManager.default.currentDirectoryPath
        let surfaceID = try continuationSurfaceID(
            for: selector,
            client: client,
            processEnvironment: processEnvironment,
            verb: .fork
        )
        let payload = try continuationSurfaceResumePayload(
            surfaceID: surfaceID,
            client: client,
            verb: .fork
        )
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
        // A direct record is an exact command replay, not an agent session
        // with fork authority. Failing closed here prevents `cmux fork` from
        // accidentally executing a recorded resume command unchanged.
        guard recordMode != .direct else {
            throw loggedForkError(
                .unsupported,
                stage: "record.mode.direct",
                detail: record.mode
            )
        }

        record = try await recoveredHermesContinuationRecord(
            record,
            surfaceID: surfaceID,
            processEnvironment: processEnvironment,
            verb: .fork
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
        var environment = processEnvironment
        if let capturedEnvironment = record.launchCommand?.environment {
            environment.merge(capturedEnvironment) { _, captured in captured }
        }
        environment.merge(record.environment) { _, restored in restored }
        if record.forkArguments == nil,
           record.launchCommand == nil,
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
        guard AgentLaunchTemplateRenderer().containsForkOption(in: legacy) else {
            return nil
        }
        return legacy
    }

}
