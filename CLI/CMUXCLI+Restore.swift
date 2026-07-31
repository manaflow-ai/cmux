import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
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
        var params: [String: Any] = [:]
        if let surface = selector.surface {
            let surfaceID = try normalizeSurfaceHandle(
                surface,
                client: client,
                workspaceHandle: nil,
                windowHandle: nil
            )
            guard let surfaceID else {
                throw CLIError(message: "restore: surface '\(surface)' was not found")
            }
            params["surface_id"] = surfaceID
        } else if let surfaceID = processEnvironment["CMUX_SURFACE_ID"] {
            params["surface_id"] = surfaceID
        }

        let payload = try client.sendV2(method: "surface.resume.get", params: params)
        guard let rawRecord = payload["restore_record"] as? [String: Any] else {
            throw CLIError(message: "restore: this surface has no restorable process record")
        }
        let record = try restoreRecord(from: rawRecord)
        if let expectedKind = selector.kind, expectedKind != record.kind {
            throw CLIError(
                message: "restore: expected kind '\(expectedKind)', but the surface records '\(record.kind)'"
            )
        }
        if let expectedCheckpointID = selector.checkpointID,
           expectedCheckpointID != record.checkpointID {
            throw CLIError(
                message: "restore: checkpoint does not match this surface's persisted record"
            )
        }

        let environment = processEnvironment.merging(record.environment) { _, restored in
            restored
        }
        if record.launchCommand == nil,
           record.preparedArguments == nil,
           let legacyCommand = record.legacyCommand {
            let appliedWorkingDirectory = try applyRestoreWorkingDirectory(record.workingDirectory)
            var legacyEnvironment = environment
            if let appliedWorkingDirectory {
                legacyEnvironment["PWD"] = appliedWorkingDirectory
            }
            client.close()
            try execLegacyRestoreCommand(legacyCommand, environment: legacyEnvironment)
        }

        guard let mode = AgentRestoreRequestMode(rawValue: record.mode) else {
            throw CLIError(message: "restore: unsupported persisted restore mode '\(record.mode)'")
        }
        let request = AgentRestoreRequest(
            mode: mode,
            kind: record.kind,
            checkpointID: record.checkpointID,
            source: record.source,
            workingDirectory: record.workingDirectory,
            environment: record.environment,
            launchCommand: record.launchCommand,
            preparedArguments: record.preparedArguments,
            observedPermissionMode: record.permissionMode
        )
        guard let invocation = AgentRestorePlanner().invocation(
            for: request,
            ambientEnvironment: processEnvironment
        ) else {
            throw CLIError(message: "restore: persisted structured launch data is incomplete")
        }

        let appliedWorkingDirectory = try applyRestoreWorkingDirectory(invocation.workingDirectory)
        for preflight in invocation.preflightInvocations {
            try runRestorePreflight(
                preflight,
                appliedWorkingDirectory: appliedWorkingDirectory
            )
        }
        client.close()
        try execRestoreInvocation(
            invocation,
            appliedWorkingDirectory: appliedWorkingDirectory
        )
    }

    private struct RestoreSelector {
        let surface: String?
        let kind: String?
        let checkpointID: String?
    }

    private struct RestoreRecord {
        let mode: String
        let kind: String
        let checkpointID: String?
        let source: String?
        let workingDirectory: String?
        let environment: [String: String]
        let launchCommand: AgentLaunchCommand?
        let preparedArguments: [String]?
        let permissionMode: String?
        let legacyCommand: String?
    }

    private func restoreSelector(_ arguments: [String]) throws -> RestoreSelector {
        if arguments.first == "--surface" {
            guard arguments.count == 2, !arguments[1].isEmpty else {
                throw CLIError(message: "Usage: cmux restore --surface <id|ref>")
            }
            return RestoreSelector(surface: arguments[1], kind: nil, checkpointID: nil)
        }
        guard arguments.count == 2,
              !arguments[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "Usage: cmux restore <kind> <checkpoint-id>")
        }
        return RestoreSelector(
            surface: nil,
            kind: arguments[0],
            checkpointID: arguments[1]
        )
    }

    private func restoreRecord(from object: [String: Any]) throws -> RestoreRecord {
        guard let mode = object["mode"] as? String,
              let kind = object["kind"] as? String else {
            throw CLIError(message: "restore: malformed restore record")
        }
        return RestoreRecord(
            mode: mode,
            kind: kind,
            checkpointID: object["checkpoint_id"] as? String,
            source: object["source"] as? String,
            workingDirectory: object["working_directory"] as? String,
            environment: object["environment"] as? [String: String] ?? [:],
            launchCommand: try restoreLaunchCommand(from: object["launch_command"]),
            preparedArguments: object["prepared_arguments"] as? [String],
            permissionMode: object["permission_mode"] as? String,
            legacyCommand: object["legacy_command"] as? String
        )
    }

    private func restoreLaunchCommand(from value: Any?) throws -> AgentLaunchCommand? {
        guard let object = value as? [String: Any] else { return nil }
        guard let arguments = object["arguments"] as? [String], !arguments.isEmpty else {
            throw CLIError(message: "restore: malformed structured launch arguments")
        }
        return AgentLaunchCommand(
            launcher: object["launcher"] as? String,
            executablePath: object["executable_path"] as? String,
            arguments: arguments,
            workingDirectory: object["working_directory"] as? String,
            environment: object["environment"] as? [String: String],
            capturedAt: (object["captured_at"] as? NSNumber)?.doubleValue,
            source: object["source"] as? String
        )
    }

    @discardableResult
    private func applyRestoreWorkingDirectory(_ path: String?) throws -> String? {
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
        throw CLIError(
            message: "restore: cannot enter working directory '\(path)': "
                + String(cString: strerror(changeDirectoryError))
        )
    }

    private func runRestorePreflight(
        _ invocation: AgentRestorePreflightInvocation,
        appliedWorkingDirectory: String?
    ) throws {
        var invocationEnvironment = invocation.environment
        if let appliedWorkingDirectory {
            invocationEnvironment["PWD"] = appliedWorkingDirectory
        }
        guard let executable = resolveRestoreExecutable(
            invocation.arguments[0],
            environment: invocationEnvironment
        ) else {
            throw CLIError(message: "restore: preflight executable '\(invocation.arguments[0])' was not found")
        }
        var processID: pid_t = 0
        let status = withCStringArray(invocation.arguments) { argv in
            withEnvironmentCStringArray(invocationEnvironment) { environment in
                executable.withCString {
                    posix_spawn(
                        &processID,
                        $0,
                        nil,
                        nil,
                        argv,
                        environment
                    )
                }
            }
        }
        guard status == 0 else {
            throw CLIError(
                message: "restore: could not start preflight: \(String(cString: strerror(status)))"
            )
        }
        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = waitpid(processID, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR
        guard waitResult == processID else {
            throw CLIError(
                message: "restore: could not wait for provider preflight: "
                    + String(cString: strerror(errno))
            )
        }
        let exitedNormally = waitStatus & 0x7f == 0
        let exitStatus = (waitStatus >> 8) & 0xff
        guard exitedNormally, exitStatus == 0 else {
            throw CLIError(message: "restore: provider preflight failed")
        }
    }

    private func execRestoreInvocation(
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
            throw CLIError(
                message: "restore: executable '\(invocation.arguments.first ?? "")' was not found"
            )
        }
        let failure = withCStringArray(invocation.arguments) { argv in
            withEnvironmentCStringArray(invocationEnvironment) { environment in
                executable.withCString {
                    let result = execve($0, argv, environment)
                    return (result, errno)
                }
            }
        }
        throw CLIError(
            message: "restore: execve failed (\(failure.0)): "
                + String(cString: strerror(failure.1))
        )
    }

    private func execLegacyRestoreCommand(
        _ command: String,
        environment: [String: String]
    ) throws {
        let shell = restoreCompatibilityShell(environment: environment)
        let arguments = [shell, "-lc", command]
        let failure = withCStringArray(arguments) { argv in
            withEnvironmentCStringArray(environment) { childEnvironment in
                shell.withCString {
                    let result = execve($0, argv, childEnvironment)
                    return (result, errno)
                }
            }
        }
        throw CLIError(
            message: "restore: compatibility shell failed (\(failure.0)): "
                + String(cString: strerror(failure.1))
        )
    }

    private func restoreCompatibilityShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"],
           shell.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let record = getpwuid(getuid()),
           let shellPointer = record.pointee.pw_shell {
            let shell = String(cString: shellPointer)
            if FileManager.default.isExecutableFile(atPath: shell) {
                return shell
            }
        }
        return "/bin/sh"
    }

    private func resolveRestoreExecutable(
        _ executable: String,
        environment: [String: String]
    ) -> String? {
        if executable.contains("/") {
            return FileManager.default.isExecutableFile(atPath: executable)
                ? executable
                : nil
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let root = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(executable, isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func withCStringArray<Result>(
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

    private func withEnvironmentCStringArray<Result>(
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
