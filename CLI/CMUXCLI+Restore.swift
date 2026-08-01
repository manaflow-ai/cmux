import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    /// Waits for the app-startup socket race only on implicit restore routing.
    func restoreSocketClient(path: String) throws -> SocketClient {
        // The live app is deliberately the sole restore-record authority: it
        // identity-checks the requesting surface, reconciles current bindings,
        // and filters persisted environments. Decoding the private session store
        // here would create a second authority that bypasses those guarantees.
        try SocketClient.waitForConnectableSocket(path: path, timeout: 10)
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
                throw CLIError(message: String(
                    localized: "cli.restore.error.surfaceNotFound",
                    defaultValue: "restore: surface '\(surface)' was not found"
                ))
            }
            params["surface_id"] = surfaceID
        } else if selector.usesCurrentSurface,
                  let surfaceID = processEnvironment["CMUX_SURFACE_ID"],
                  !surfaceID.isEmpty {
            params["surface_id"] = surfaceID
        } else if selector.usesCurrentSurface,
                  let ttyName = resolveCallerTTYName(),
                  let caller = resolveTerminalBinding(
                      ttyName: ttyName,
                      client: client
                  ) {
            params["surface_id"] = caller.surfaceId
        } else {
            throw CLIError(
                message: String(
                    localized: "cli.restore.error.currentSurfaceUnknown",
                    defaultValue: "restore: the current cmux surface could not be identified. Retry from this terminal or pass --surface <id|ref>."
                )
            )
        }

        let payload = try client.sendV2(method: "surface.resume.get", params: params)
        guard let rawRecord = payload["restore_record"] as? [String: Any] else {
            throw CLIError(message: String(
                localized: "cli.restore.error.noRecord",
                defaultValue: "restore: this surface has no restorable process record"
            ))
        }
        let record = try restoreRecord(from: rawRecord)
        if let expectedKind = selector.kind, expectedKind != record.kind {
            throw CLIError(
                message: String(
                    localized: "cli.restore.error.kindMismatch",
                    defaultValue: "restore: expected kind '\(expectedKind)', but the surface records '\(record.kind)'. Run 'cmux restore --surface' to use the current record."
                )
            )
        }
        if let expectedCheckpointID = selector.checkpointID,
           expectedCheckpointID != record.checkpointID {
            throw CLIError(
                message: String(
                    localized: "cli.restore.error.checkpointMismatch",
                    defaultValue: "restore: checkpoint does not match this surface's persisted record. Run 'cmux restore --surface' to use the current record."
                )
            )
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
                environment: environment,
                client: client
            )
        }

        guard let mode = AgentRestoreRequestMode(rawValue: record.mode) else {
            throw CLIError(message: String(
                localized: "cli.restore.error.unsupportedMode",
                defaultValue: "restore: unsupported persisted restore mode '\(record.mode)'"
            ))
        }
        let requestedWorkingDirectory = requestedRestoreWorkingDirectory(for: record)
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
                try execLegacyRestoreRecord(
                    legacyCommand,
                    record: record,
                    environment: environment,
                    client: client
                )
            }
            throw CLIError(message: String(
                localized: "cli.restore.error.incompleteData",
                defaultValue: "restore: persisted structured launch data is incomplete"
            ))
        }

        for preflight in invocation.preflightInvocations {
            try runRestorePreflight(
                preflight,
                appliedWorkingDirectory: effectiveWorkingDirectory
            )
        }
        client.close()
        try execRestoreInvocation(
            invocation,
            appliedWorkingDirectory: effectiveWorkingDirectory
        )
    }

    private func restoreSelector(_ arguments: [String]) throws -> RestoreSelector {
        if arguments.first == "--surface" {
            if arguments.count == 1 {
                return RestoreSelector(
                    surface: nil,
                    usesCurrentSurface: true,
                    kind: nil,
                    checkpointID: nil
                )
            }
            guard arguments.count == 2, !arguments[1].isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.restore.usage.surface",
                    defaultValue: "Usage: cmux restore --surface [id|ref]"
                ))
            }
            return RestoreSelector(
                surface: arguments[1],
                usesCurrentSurface: false,
                kind: nil,
                checkpointID: nil
            )
        }
        guard arguments.count == 2,
              !arguments[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: String(
                localized: "cli.restore.usage.positional",
                defaultValue: "Usage: cmux restore <kind> <checkpoint-id>"
            ))
        }
        return RestoreSelector(
            surface: nil,
            usesCurrentSurface: true,
            kind: arguments[0],
            checkpointID: arguments[1]
        )
    }

    private func restoreRecord(from object: [String: Any]) throws -> RestoreRecord {
        guard let mode = object["mode"] as? String,
              let kind = object["kind"] as? String else {
            throw CLIError(message: String(
                localized: "cli.restore.error.malformedRecord",
                defaultValue: "restore: malformed restore record"
            ))
        }
        let legacyCommand = object["legacy_command"] as? String
        let launchCommand: AgentLaunchCommand?
        do {
            launchCommand = try restoreLaunchCommand(from: object["launch_command"])
        } catch {
            guard legacyCommand != nil else {
                throw error
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
                defaultValue: "restore: malformed structured launch arguments"
            ))
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
            message: String(
                localized: "cli.restore.error.workingDirectoryFailed",
                defaultValue: "restore: cannot enter working directory '\(path)': \(String(cString: strerror(changeDirectoryError)))"
            )
        )
    }

    private func requestedRestoreWorkingDirectory(for record: RestoreRecord) -> String? {
        normalizedRestoreWorkingDirectory(record.workingDirectory)
            ?? normalizedRestoreWorkingDirectory(record.launchCommand?.workingDirectory)
    }

    private func normalizedRestoreWorkingDirectory(_ path: String?) -> String? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
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
                message: String(
                    localized: "cli.restore.error.executableNotFound",
                    defaultValue: "restore: executable '\(invocation.arguments.first ?? "")' was not found"
                )
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
            message: String(
                localized: "cli.restore.error.execveFailed",
                defaultValue: "restore: execve failed (\(failure.0)): \(String(cString: strerror(failure.1)))"
            )
        )
    }

    private func execLegacyRestoreRecord(
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
        let failure = withCStringArray(arguments) { argv in
            withEnvironmentCStringArray(environment) { childEnvironment in
                shell.withCString {
                    let result = execve($0, argv, childEnvironment)
                    return (result, errno)
                }
            }
        }
        throw CLIError(
            message: String(
                localized: "cli.restore.error.compatibilityShellFailed",
                defaultValue: "restore: compatibility shell failed (\(failure.0)): \(String(cString: strerror(failure.1)))"
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
