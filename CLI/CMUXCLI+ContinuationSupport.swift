import CMUXAgentLaunch
import Foundation

/// The command family sharing surface-selector and restore-record semantics.
enum CMUXCLIContinuationVerb: String, Sendable {
    case restore
    case fork

    var commandName: String { rawValue }
}

enum CMUXCLIContinuationErrorKind: Sendable, Equatable {
    case checkpointNotFound
    case surfaceUsage
    case positionalUsage
    case malformedRecord
    case malformedArguments
    case surfaceNotFound
    case currentSurfaceUnknown
}

extension CMUXCLI {
    /// Dispatches the two continuation verbs through their shared socket setup.
    func runContinuationCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        processEnvironment: [String: String]
    ) async throws {
        if command == CMUXCLIContinuationVerb.fork.commandName {
            try await runForkCommand(
                commandArgs: commandArgs,
                client: client,
                processEnvironment: processEnvironment
            )
        } else {
            try await runRestoreCommand(
                commandArgs: commandArgs,
                client: client,
                processEnvironment: processEnvironment
            )
        }
    }

    /// Maps a startup wait failure to the verb-specific localized error.
    func continuationSocketStartupError(
        command: String,
        error: Error
    ) -> CLIError {
        let detail = String(reflecting: error)
        if command == CMUXCLIContinuationVerb.fork.commandName {
            return loggedForkError(
                .socketNotReady,
                stage: "socket.startup",
                detail: detail
            )
        }
        return loggedRestoreError(
            stage: "socket.startup",
            detail: detail,
            message: String(
                localized: "cli.restore.error.socketNotReady",
                defaultValue: "restore: cmux is still opening. Retry the visible restore command in a moment."
            )
        )
    }

    /// Parses the selector grammar shared by `cmux restore` and `cmux fork`.
    func continuationSelector(
        _ arguments: [String],
        verb: CMUXCLIContinuationVerb
    ) throws -> RestoreSelector {
        if arguments == ["--surface"] {
            return RestoreSelector(
                surface: nil,
                usesCurrentSurface: true,
                kind: nil,
                checkpointID: nil
            )
        }

        let surfaceOptionCount = arguments.filter { argument in
            argument == "--surface" || argument.hasPrefix("--surface=")
        }.count
        guard surfaceOptionCount <= 1 else {
            throw continuationUsageError(.surfaceUsage, verb: verb)
        }
        let (surface, positionalArguments) = parseOption(arguments, name: "--surface")
        if surfaceOptionCount == 1 {
            guard let surface,
                  !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw continuationUsageError(.surfaceUsage, verb: verb)
            }
            if positionalArguments.isEmpty {
                return RestoreSelector(
                    surface: surface,
                    usesCurrentSurface: false,
                    kind: nil,
                    checkpointID: nil
                )
            }
        }

        guard positionalArguments.count == 2,
              !positionalArguments[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !positionalArguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw continuationUsageError(.positionalUsage, verb: verb)
        }
        return RestoreSelector(
            surface: surface,
            usesCurrentSurface: surface == nil,
            kind: positionalArguments[0],
            checkpointID: positionalArguments[1]
        )
    }

    /// Returns the localized parser error for one continuation verb.
    func continuationUsageError(
        _ kind: CMUXCLIContinuationErrorKind,
        verb: CMUXCLIContinuationVerb
    ) -> CLIError {
        switch (verb, kind) {
        case (.restore, .checkpointNotFound):
            return CLIError(message: String(
                localized: "cli.restore.error.noRecord",
                defaultValue: "restore: this session has nothing to restore. Start the agent again in this terminal."
            ))
        case (.fork, .checkpointNotFound):
            return CLIError(message: String(
                localized: "cli.fork.error.noRecord",
                defaultValue: "fork: this session has nothing to fork. Start the agent again in this terminal."
            ))
        case (.restore, .surfaceUsage):
            return CLIError(message: String(
                localized: "cli.restore.usage.surface",
                defaultValue: "Usage: cmux restore --surface [id|ref]"
            ))
        case (.restore, .positionalUsage):
            return CLIError(message: String(
                localized: "cli.restore.usage.positional",
                defaultValue: """
                Usage: cmux restore [--surface <id|ref>] <kind> <checkpoint-id>
                       cmux restore <kind> <checkpoint-id> --surface <id|ref>
                       cmux restore --surface=<id|ref> <kind> <checkpoint-id>
                """
            ))
        case (.fork, .surfaceUsage):
            return CLIError(message: String(
                localized: "cli.fork.usage.surface",
                defaultValue: "Usage: cmux fork --surface [id|ref]"
            ))
        case (.fork, .positionalUsage):
            return CLIError(message: String(
                localized: "cli.fork.usage.positional",
                defaultValue: """
                Usage: cmux fork [--surface <id|ref>] <kind> <checkpoint-id>
                       cmux fork <kind> <checkpoint-id> --surface <id|ref>
                       cmux fork --surface=<id|ref> <kind> <checkpoint-id>
                """
            ))
        case (.restore, .surfaceNotFound):
            return CLIError(message: String(
                localized: "cli.restore.error.surfaceNotFound",
                defaultValue: "restore: the requested surface was not found. Check the surface reference, then retry."
            ))
        case (.fork, .surfaceNotFound):
            return CLIError(message: String(
                localized: "cli.fork.error.surfaceNotFound",
                defaultValue: "fork: the requested surface was not found. Check the surface reference, then retry."
            ))
        case (.restore, .currentSurfaceUnknown):
            return CLIError(message: String(
                localized: "cli.restore.error.currentSurfaceUnknown",
                defaultValue: "restore: the current cmux surface could not be identified. Retry from this terminal or pass --surface <id|ref>."
            ))
        case (.fork, .currentSurfaceUnknown):
            return CLIError(message: String(
                localized: "cli.fork.error.currentSurfaceUnknown",
                defaultValue: "fork: the current cmux surface could not be identified. Retry from this terminal or pass --surface <id|ref>."
            ))
        case (.restore, .malformedRecord):
            return CLIError(message: String(
                localized: "cli.restore.error.malformedRecord",
                defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
            ))
        case (.restore, .malformedArguments):
            return CLIError(message: String(
                localized: "cli.restore.error.malformedArguments",
                defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
            ))
        case (.fork, .malformedRecord):
            return CLIError(message: String(
                localized: "cli.fork.error.malformedRecord",
                defaultValue: "fork: this session's saved restore data is not compatible. Start the agent again in this terminal."
            ))
        case (.fork, .malformedArguments):
            return CLIError(message: String(
                localized: "cli.fork.error.malformedArguments",
                defaultValue: "fork: this session's saved restore data is not compatible. Start the agent again in this terminal."
            ))
        }
    }

    /// Logs a continuation failure while selecting the command-specific localized message.
    func loggedContinuationError(
        _ kind: CMUXCLIContinuationErrorKind,
        verb: CMUXCLIContinuationVerb,
        stage: String,
        detail: String = "none",
        errorCode: Int32? = nil
    ) -> CLIError {
        let message = continuationUsageError(kind, verb: verb).message
        switch verb {
        case .restore:
            return loggedRestoreError(
                stage: stage,
                detail: detail,
                errorCode: errorCode,
                message: message
            )
        case .fork:
            logForkFailure(stage: stage, detail: detail, errorCode: errorCode)
            return CLIError(message: message)
        }
    }

    /// Resolves the explicit or calling surface for either continuation verb.
    func continuationSurfaceID(
        for selector: RestoreSelector,
        client: SocketClient,
        processEnvironment: [String: String],
        verb: CMUXCLIContinuationVerb
    ) throws -> String {
        if let surface = selector.surface {
            let surfaceID: String?
            do {
                surfaceID = try normalizeSurfaceHandle(
                    surface,
                    client: client,
                    workspaceHandle: nil,
                    windowHandle: nil
                )
            } catch {
                guard isContinuationSurfaceNotFound(error) else { throw error }
                throw loggedContinuationError(
                    .surfaceNotFound,
                    verb: verb,
                    stage: "surface.lookup",
                    detail: surface
                )
            }
            guard let surfaceID else {
                throw loggedContinuationError(
                    .surfaceNotFound,
                    verb: verb,
                    stage: "surface.lookup",
                    detail: surface
                )
            }
            return surfaceID
        }
        guard selector.usesCurrentSurface else {
            throw loggedContinuationError(
                .currentSurfaceUnknown,
                verb: verb,
                stage: "surface.current"
            )
        }
        do {
            if let surfaceID = try currentRestoreSurfaceID(
                client: client,
                processEnvironment: processEnvironment
            ) {
                return surfaceID
            }
        } catch {
            if verb == .restore {
                // Preserve restore's established transport/error behavior; fork
                // gets the parallel product-level surface diagnostic below.
                throw error
            }
            throw loggedContinuationError(
                .currentSurfaceUnknown,
                verb: verb,
                stage: "surface.current",
                detail: String(reflecting: type(of: error))
            )
        }
        throw loggedContinuationError(
            .currentSurfaceUnknown,
            verb: verb,
            stage: "surface.current"
        )
    }

    /// Fetches the continuation record while translating only a genuine
    /// missing-surface response into the verb-specific localized diagnostic.
    func continuationSurfaceResumePayload(
        surfaceID: String,
        client: SocketClient,
        verb: CMUXCLIContinuationVerb
    ) throws -> [String: Any] {
        do {
            return try client.sendV2(
                method: "surface.resume.get",
                params: ["surface_id": surfaceID]
            )
        } catch {
            guard isContinuationSurfaceNotFound(error) else { throw error }
            throw loggedContinuationError(
                .surfaceNotFound,
                verb: verb,
                stage: "surface.resume.lookup",
                detail: surfaceID
            )
        }
    }

    /// Identifies only the not-found failures emitted by surface-handle lookup.
    /// Invalid handles and transport failures retain their established errors.
    func isContinuationSurfaceNotFound(_ error: Error) -> Bool {
        guard let cliError = error as? CLIError else { return false }
        if cliError.v2Code == "not_found" { return true }
        let message = cliError.message.lowercased()
        return message == "surface not found"
            || message == "surface index not found"
            || message == "surface not found in window"
    }

    /// Repairs a transient Hermes checkpoint for either continuation verb.
    ///
    /// Hermes can persist a short-lived TUI identity before its durable
    /// conversation row exists. Keep this recovery seam shared so `restore`
    /// and `fork` make the same identity decision and report the same class of
    /// missing-checkpoint failure with their verb-specific copy.
    func recoveredHermesContinuationRecord(
        _ record: RestoreRecord,
        surfaceID: String,
        processEnvironment: [String: String],
        verb: CMUXCLIContinuationVerb
    ) async throws -> RestoreRecord {
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
        let expectedWorkingDirectory = record.workingDirectory
            ?? record.launchCommand?.workingDirectory
        let resolution = await Self.resolveHermesCheckpoint(
            surfaceID: surfaceUUID,
            checkpointID: checkpointID,
            expectedWorkingDirectory: expectedWorkingDirectory,
            hookStatePath: hookStatePath,
            environment: recoveryEnvironment
        )
        switch resolution {
        case .valid, .legacyRestore, .unavailable:
            return record
        case .missing:
            throw loggedContinuationError(
                .checkpointNotFound,
                verb: verb,
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

    /// Performs the focused Hermes state read on Swift's concurrent executor.
    @concurrent
    private static func resolveHermesCheckpoint(
        surfaceID: UUID,
        checkpointID: String,
        expectedWorkingDirectory: String?,
        hookStatePath: String,
        environment: [String: String]
    ) async -> HermesLegacySessionIdentityRecovery.Resolution {
        HermesLegacySessionIdentityRecovery().resolve(
            surfaceID: surfaceID,
            corruptSessionID: checkpointID,
            expectedWorkingDirectory: expectedWorkingDirectory,
            hookStateFileURL: URL(fileURLWithPath: hookStatePath),
            environment: environment
        )
    }
}
