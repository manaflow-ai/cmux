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
        if chdir(path) == 0 {
            return path
        }
        let changeDirectoryError = errno
        // Preserve the old guarded `cd`: a directory removed since capture
        // falls back to the shell's current directory, while an existing but
        // inaccessible path still blocks restore.
        if changeDirectoryError == ENOENT || changeDirectoryError == ENOTDIR {
            return nil
        }
        throw loggedRestoreError(
            stage: "working-directory.change",
            detail: path,
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
        environment: [String: String],
        client: SocketClient
    ) throws {
        let appliedWorkingDirectory = try applyRestoreWorkingDirectory(
            requestedRestoreWorkingDirectory(for: record)
        )
        var legacyEnvironment = environment
        if let appliedWorkingDirectory {
            legacyEnvironment["PWD"] = appliedWorkingDirectory
        }
        client.close()
        try execLegacyRestoreCommand(command, environment: legacyEnvironment)
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
