import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    @discardableResult
    func applyRestoreWorkingDirectory(_ path: String?) throws -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        let resolvedPath: String = if path.hasPrefix("/") {
            path
        } else {
            URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            .appendingPathComponent(path, isDirectory: true)
            .standardizedFileURL.path
        }
        if chdir(resolvedPath) == 0 {
            return resolvedPath
        }
        let changeDirectoryError = errno
        if changeDirectoryError == ENOENT || changeDirectoryError == ENOTDIR {
            throw loggedRestoreError(
                stage: "working-directory.missing",
                detail: resolvedPath,
                errorCode: changeDirectoryError,
                message: String(
                    localized: "cli.restore.error.workingDirectoryMissing",
                    defaultValue: "restore: the saved working directory is missing. Choose a recovery directory explicitly before retrying. Pass --cwd <path> to use that directory."
                )
            )
        }
        throw loggedRestoreError(
            stage: "working-directory.change",
            detail: resolvedPath,
            errorCode: changeDirectoryError,
            message: String(
                localized: "cli.restore.error.workingDirectoryFailed",
                defaultValue: "restore: the saved working directory is inaccessible. Restore access to it, then retry."
            )
        )
    }

    func requestedRestoreWorkingDirectory(for record: RestoreRecord) -> String? {
        normalizedRestoreWorkingDirectory(record.workingDirectory)
            ?? normalizedRestoreWorkingDirectory(record.launchCommand?.workingDirectory)
    }

    func normalizedRestoreWorkingDirectory(_ path: String?) -> String? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func execRestoreInvocation(
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
            throw loggedRestoreError(
                stage: "executable.resolve",
                detail: invocation.arguments.first ?? "none",
                message: String(
                    localized: "cli.restore.error.executableNotFound",
                    defaultValue: "restore: the saved agent command is unavailable. Make sure the agent is installed, then retry."
                )
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
        throw loggedRestoreError(
            stage: "executable.exec",
            detail: executable,
            errorCode: executionError,
            message: String(
                localized: "cli.restore.error.execveFailed",
                defaultValue: "restore: the saved process could not be started. Retry the visible restore command."
            )
        )
    }

    func execLegacyRestoreRecord(
        _ command: String,
        record: RestoreRecord,
        workingDirectoryOverride: String?,
        environment: [String: String],
        client: SocketClient
    ) throws {
        let appliedWorkingDirectory = try applyRestoreWorkingDirectory(
            workingDirectoryOverride ?? requestedRestoreWorkingDirectory(for: record)
        )
        let command = try retargetedLegacyRestoreCommand(
            command,
            record: record,
            workingDirectoryOverride: workingDirectoryOverride,
            appliedWorkingDirectory: appliedWorkingDirectory
        )
        var legacyEnvironment = environment
        if let appliedWorkingDirectory {
            legacyEnvironment["PWD"] = appliedWorkingDirectory
        }
        client.close()
        try execLegacyRestoreCommand(command, environment: legacyEnvironment)
    }

    private func retargetedLegacyRestoreCommand(
        _ command: String,
        record: RestoreRecord,
        workingDirectoryOverride: String?,
        appliedWorkingDirectory: String?
    ) throws -> String {
        guard normalizedRestoreWorkingDirectory(workingDirectoryOverride) != nil,
              let appliedWorkingDirectory else {
            return command
        }

        let previousWorkingDirectories = [
            normalizedRestoreWorkingDirectory(record.workingDirectory),
            normalizedRestoreWorkingDirectory(record.launchCommand?.workingDirectory),
            normalizedRestoreWorkingDirectory(record.preparedArgumentsWorkingDirectory),
        ].compactMap { $0 }
        var seenWorkingDirectories: Set<String> = []
        for previousWorkingDirectory in previousWorkingDirectories
            where seenWorkingDirectories.insert(previousWorkingDirectory).inserted {
            let quotedCandidates = [
                legacyRestoreShellSingleQuote(previousWorkingDirectory),
                shellQuote(previousWorkingDirectory),
            ]
            var seenQuotedCandidates: Set<String> = []
            for quoted in quotedCandidates where seenQuotedCandidates.insert(quoted).inserted {
                let prefixes = [
                    "cd -- \(quoted) 2>/dev/null && ",
                    "cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ] && ",
                    "{ cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ]; } && ",
                    "{ [ ! -d \(quoted) ] || cd -- \(quoted); } && ",
                    "cd -- \(quoted) && ",
                    "cd \(quoted) && ",
                ]
                for prefix in prefixes where command.hasPrefix(prefix) {
                    let replacement = "cd -- \(legacyRestoreShellSingleQuote(appliedWorkingDirectory)) 2>/dev/null && "
                    return replacement + command.dropFirst(prefix.count)
                }
            }
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUnrecognizedWorkingDirectoryPrefix = trimmed.hasPrefix("cd ") ||
            trimmed.hasPrefix("cd\t") ||
            trimmed.hasPrefix("{ cd ") ||
            trimmed.hasPrefix("{ cd\t") ||
            trimmed.hasPrefix("{ [ ! -d ")
        guard !hasUnrecognizedWorkingDirectoryPrefix else {
            throw loggedRestoreError(
                stage: "legacy-working-directory.retarget",
                detail: "kind=\(record.kind)",
                message: String(
                    localized: "cli.restore.error.incompleteData",
                    defaultValue: "restore: this session's saved restore data is not compatible. Start the agent again in this terminal."
                )
            )
        }
        return command
    }

    private func legacyRestoreShellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func execLegacyRestoreCommand(
        _ command: String,
        environment: [String: String]
    ) throws {
        let shell = restoreCompatibilityShell(environment: environment)
        let arguments = [shell, "-lc", command]
        let executionError = withCStringArray(arguments) { argv in
            withEnvironmentCStringArray(environment) { childEnvironment in
                shell.withCString {
                    _ = execve($0, argv, childEnvironment)
                    return errno
                }
            }
        }
        throw loggedRestoreError(
            stage: "legacy-shell.exec",
            detail: shell,
            errorCode: executionError,
            message: String(
                localized: "cli.restore.error.compatibilityShellFailed",
                defaultValue: "restore: the saved process could not be started. Retry the visible restore command."
            )
        )
    }

    private func restoreCompatibilityShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"],
           shell.hasPrefix("/"),
           isExecutableRegularFile(atPath: shell) {
            return shell
        }
        if let record = getpwuid(getuid()),
           let shellPointer = record.pointee.pw_shell {
            let shell = String(cString: shellPointer)
            if isExecutableRegularFile(atPath: shell) {
                return shell
            }
        }
        return "/bin/sh"
    }

    func resolveRestoreExecutable(
        _ executable: String,
        environment: [String: String]
    ) -> String? {
        if executable.contains("/") {
            return isExecutableRegularFile(atPath: executable)
                ? executable
                : nil
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // Shells treat an empty PATH component as the current directory. Restore
        // may already be inside an untrusted project, so fail closed instead.
        for directory in path.split(separator: ":") {
            let root = String(directory)
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(executable, isDirectory: false)
                .path
            if isExecutableRegularFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isExecutableRegularFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer {
            body($0.baseAddress)
        }
    }

    func withEnvironmentCStringArray<Result>(
        _ environment: [String: String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        withCStringArray(
            environment.keys.sorted().compactMap { key in
                environment[key].map { "\(key)=\($0)" }
            },
            body: body
        )
    }
}
