import CMUXAgentLaunch
import Darwin
import Foundation
import OSLog

nonisolated private let forkFailureLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "Fork"
)

extension CMUXCLI {
    enum ForkErrorKind: Equatable {
        case noRecord
        case kindMismatch
        case checkpointMismatch
        case unsupportedMode
        case incompleteData
        case unsupported
        case providerSetupFailed
        case workingDirectoryFailed
        case executableNotFound
        case execveFailed
        case compatibilityShellFailed
        case codexCheckpointUnavailable
        case socketNotReady
    }

    func forkErrorMessage(_ kind: ForkErrorKind) -> String {
        switch kind {
        case .noRecord:
            return String(
                localized: "cli.fork.error.noRecord",
                defaultValue: "fork: this session has nothing to fork. Start the agent again in this terminal."
            )
        case .kindMismatch:
            return String(
                localized: "cli.fork.error.kindMismatch",
                defaultValue: "fork: this command no longer matches the session. Run 'cmux fork --surface' to use the current record."
            )
        case .checkpointMismatch:
            return String(
                localized: "cli.fork.error.checkpointMismatch",
                defaultValue: "fork: this command no longer matches the session. Run 'cmux fork --surface' to use the current record."
            )
        case .unsupportedMode:
            return String(
                localized: "cli.fork.error.unsupportedMode",
                defaultValue: "fork: this session's saved fork data is not compatible. Start the agent again in this terminal."
            )
        case .incompleteData:
            return String(
                localized: "cli.fork.error.incompleteData",
                defaultValue: "fork: this session's saved fork data is not compatible. Start the agent again in this terminal."
            )
        case .unsupported:
            return String(
                localized: "cli.fork.error.unsupported",
                defaultValue: "fork: this agent does not support forking. Configure a fork command for this agent, then retry."
            )
        case .providerSetupFailed:
            return String(
                localized: "cli.fork.error.providerSetupFailed",
                defaultValue: "fork: provider setup failed. Check the agent's provider settings, then retry."
            )
        case .workingDirectoryFailed:
            return String(
                localized: "cli.fork.error.workingDirectoryFailed",
                defaultValue: "fork: the saved working directory is inaccessible. Restore access to it, then retry."
            )
        case .executableNotFound:
            return String(
                localized: "cli.fork.error.executableNotFound",
                defaultValue: "fork: the saved agent command is unavailable. Make sure the agent is installed, then retry."
            )
        case .execveFailed:
            return String(
                localized: "cli.fork.error.execveFailed",
                defaultValue: "fork: the saved process could not be started. Retry the visible fork command."
            )
        case .compatibilityShellFailed:
            return String(
                localized: "cli.fork.error.compatibilityShellFailed",
                defaultValue: "fork: the saved process could not be started. Retry the visible fork command."
            )
        case .codexCheckpointUnavailable:
            return String(
                localized: "cli.fork.codexCheckpointUnavailable",
                defaultValue: "fork: the saved agent session is unavailable. The terminal remains in its saved directory; retry later or start a new agent session."
            )
        case .socketNotReady:
            return String(
                localized: "cli.fork.error.socketNotReady",
                defaultValue: "fork: cmux is still opening. Retry the visible fork command in a moment."
            )
        }
    }

    func loggedForkError(
        _ kind: ForkErrorKind,
        stage: String,
        detail: String = "none",
        errorCode: Int32? = nil
    ) -> CLIError {
        logForkFailure(stage: stage, detail: detail, errorCode: errorCode)
        return CLIError(message: forkErrorMessage(kind))
    }

    /// Records private fork diagnostics while returning a product-level error.
    func logForkFailure(
        stage: String,
        detail: String = "none",
        errorCode: Int32? = nil
    ) {
        let loggedErrorCode = errorCode.map { String($0) } ?? "none"
        forkFailureLogger.error(
            "Fork failed stage=\(stage, privacy: .public) detail=\(detail, privacy: .private(mask: .hash)) errorCode=\(loggedErrorCode, privacy: .private(mask: .hash))"
        )
    }

    func applyForkWorkingDirectory(_ path: String?) throws -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        if chdir(path) == 0 {
            return path
        }
        let changeDirectoryError = errno
        if changeDirectoryError == ENOENT || changeDirectoryError == ENOTDIR {
            return nil
        }
        throw loggedForkError(
            .workingDirectoryFailed,
            stage: "working-directory.change",
            detail: path,
            errorCode: changeDirectoryError
        )
    }

    /// Reports whether the record contains a sanitizer-approved structured fork
    /// form. This keeps the missing-registration error distinct from malformed
    /// structured data while allowing native kinds to derive argv on older records.
    func recordCanBuildFork(_ record: RestoreRecord) -> Bool {
        if record.forkArguments?.isEmpty == false {
            return true
        }
        guard let checkpointID = normalizedHookValue(record.checkpointID),
              let launchCommand = record.launchCommand else {
            return false
        }
        switch AgentForkArgv().launcherResolution(
            launcher: launchCommand.launcher,
            sessionId: checkpointID,
            executablePath: launchCommand.executablePath,
            arguments: launchCommand.arguments
        ) {
        case .resolved(let arguments):
            return arguments?.isEmpty == false
        case .passthrough:
            return AgentForkArgv().builtInKind(
                kind: record.kind,
                sessionId: checkpointID,
                executablePath: launchCommand.executablePath,
                arguments: launchCommand.arguments,
                observedPermissionMode: record.permissionMode
            )?.isEmpty == false
        }
    }

    func execForkInvocation(
        _ invocation: AgentRestoreInvocation,
        appliedWorkingDirectory: String?
    ) throws {
        var invocationEnvironment = invocation.environment
        if let appliedWorkingDirectory {
            invocationEnvironment["PWD"] = appliedWorkingDirectory
        }
        guard let first = invocation.arguments.first,
              let executable = resolveRestoreExecutable(
                  first,
                  environment: invocationEnvironment
              ) else {
            throw loggedForkError(
                .executableNotFound,
                stage: "executable.resolve",
                detail: invocation.arguments.first ?? "none"
            )
        }
        let executionError = withCStringArray(invocation.arguments) { argv in
            withEnvironmentCStringArray(invocationEnvironment) { environment in
                executable.withCString {
                    _ = execve($0, argv, environment)
                    return errno
                }
            }
        }
        throw loggedForkError(
            .execveFailed,
            stage: "executable.exec",
            detail: executable,
            errorCode: executionError
        )
    }

    func execLegacyForkRecord(
        _ command: String,
        record: RestoreRecord,
        environment: [String: String],
        client: SocketClient
    ) throws {
        let appliedWorkingDirectory = try applyForkWorkingDirectory(
            requestedRestoreWorkingDirectory(for: record)
        )
        var legacyEnvironment = environment
        if let appliedWorkingDirectory {
            legacyEnvironment["PWD"] = appliedWorkingDirectory
        }
        client.close()
        let shell = forkCompatibilityShell(environment: legacyEnvironment)
        let arguments = [shell, "-lc", command]
        let executionError = withCStringArray(arguments) { argv in
            withEnvironmentCStringArray(legacyEnvironment) { childEnvironment in
                shell.withCString {
                    _ = execve($0, argv, childEnvironment)
                    return errno
                }
            }
        }
        throw loggedForkError(
            .compatibilityShellFailed,
            stage: "legacy-shell.exec",
            detail: shell,
            errorCode: executionError
        )
    }

    private func forkCompatibilityShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"],
           shell.hasPrefix("/"),
           isForkExecutableRegularFile(atPath: shell) {
            return shell
        }
        if let record = getpwuid(getuid()),
           let shellPointer = record.pointee.pw_shell {
            let shell = String(cString: shellPointer)
            if isForkExecutableRegularFile(atPath: shell) {
                return shell
            }
        }
        return "/bin/sh"
    }

    private func isForkExecutableRegularFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    func handleRejectedCodexFork(
        _ result: CodexRestoreValidationResult,
        record: RestoreRecord,
        bindingPayload: [String: Any]?,
        surfaceID: String?,
        workspaceID: String?,
        client: SocketClient,
        workingDirectoryBeforeFork: String
    ) throws {
        switch result {
        case .allowed:
            return
        case .bindingChanged:
            _ = try? applyForkWorkingDirectory(workingDirectoryBeforeFork)
        case .missing, .unavailable, .rejectedChild:
            let workingDirectory = requestedRestoreWorkingDirectory(for: record)
                ?? normalizedHookValue(bindingPayload?["cwd"] as? String)
            _ = try applyForkWorkingDirectory(workingDirectory)
        }

        let shouldClear = switch result {
        case .missing, .rejectedChild: true
        case .allowed, .unavailable, .bindingChanged: false
        }
        if shouldClear,
           isCodexForkBindingOwner(bindingPayload, checkpointID: record.checkpointID),
           let surfaceID,
           let checkpointID = normalizedHookValue(record.checkpointID) {
            _ = clearAgentSurfaceResumeBindingOutcome(
                client: client,
                workspaceId: workspaceID ?? "",
                surfaceId: surfaceID,
                sessionId: checkpointID,
                updatedAt: (bindingPayload?["updated_at"] as? NSNumber)?.doubleValue,
                sessionDidEnd: true
            )
        }
        switch result {
        case .bindingChanged:
            throw loggedForkError(
                .checkpointMismatch,
                stage: "codex.fork.binding-changed"
            )
        case .missing, .unavailable, .rejectedChild:
            throw loggedForkError(
                .codexCheckpointUnavailable,
                stage: "codex.fork.checkpoint-unavailable"
            )
        case .allowed:
            return
        }
    }

    private func isCodexForkBindingOwner(
        _ bindingPayload: [String: Any]?,
        checkpointID: String?
    ) -> Bool {
        guard let bindingCheckpoint = codexRestoreBindingCheckpoint(bindingPayload),
              let checkpointID = normalizedHookValue(checkpointID) else {
            return false
        }
        return bindingCheckpoint == checkpointID
    }
}
