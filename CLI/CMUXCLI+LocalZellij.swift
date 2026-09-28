import Darwin
import Foundation

/// Registry, command builder, and process runner for one local-zellij command.
struct LocalZellijRuntime {
    let registry: LocalTmuxSessionRegistry
    let builder: LocalZellijCommandBuilder
    let runner: LocalTmuxProcessRunner

    /// Sessions zellij would attach to by name: live ones in the private
    /// socket directory and exited ones it can resurrect.
    func sessions() throws -> [LocalZellijSessionListParser.Session] {
        let result = try runner.run(arguments: builder.listSessionsArguments())
        guard let sessions = LocalZellijSessionListParser().sessions(result) else {
            throw CLIError(message: String(localized: "cli.localZellij.error.listFailed", defaultValue: "local-zellij could not list sessions; liveness is unknown."))
        }
        return sessions
    }
}

extension CMUXCLI {
    /// Runs the opt-in local zellij profile. The ordinary terminal path never
    /// enters this method. `client` is nil when the command runs without the
    /// cmux app, which only actions that `canRunWithoutCmux` do.
    func runLocalZellijCommand(
        commandArgs: [String],
        client: SocketClient?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String? = nil
    ) throws {
        var invocation = try LocalZellijInvocation.parse(commandArgs)
        if let windowOverride,
           invocation.attachRequest.window == nil,
           invocation.action == .start || invocation.action == .attach {
            invocation.attachRequest.window = windowOverride
        }
        let runtime = try localZellijRuntime()
        switch invocation.action {
        case .list:
            try listLocalZellijSessions(runtime: runtime, jsonOutput: jsonOutput, idFormat: idFormat)
        case .status:
            let record = try requireLocalZellijRecord(invocation, runtime: runtime)
            try statusLocalZellijSession(record: record, runtime: runtime, jsonOutput: jsonOutput, idFormat: idFormat)
        case .close:
            try withLocalZellijLifecycleLock(runtime) {
                let record = try requireLocalZellijRecord(invocation, runtime: runtime)
                try closeLocalZellijSession(record: record, runtime: runtime, jsonOutput: jsonOutput, idFormat: idFormat)
            }
        case .start:
            let record = try withLocalZellijLifecycleLock(runtime) {
                try startLocalZellijSession(invocation: invocation, runtime: runtime)
            }
            if invocation.headless, !invocation.detached {
                try runLocalZellijInteractiveAttach(record: record, runtime: runtime)
            } else if invocation.detached || invocation.headless {
                printLocalZellijRecord(record, state: "detached", jsonOutput: jsonOutput, idFormat: idFormat)
            } else {
                try attachLocalZellijClient(record: record, invocation: invocation, runtime: runtime, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
            }
        case .attach:
            let record = try requireLocalZellijRecord(invocation, runtime: runtime)
            // An exited session is attachable: zellij resurrects it. The
            // tokenized name keeps that to sessions this profile started.
            let zellijName = LocalZellijCommandBuilder.zellijSessionName(for: record)
            guard try runtime.sessions().contains(where: { $0.name == zellijName }) else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localZellij.error.sessionNotRunning", defaultValue: "local-zellij session is no longer running: %@"),
                    record.name
                ))
            }
            if invocation.headless {
                try runLocalZellijInteractiveAttach(record: record, runtime: runtime)
            } else {
                try attachLocalZellijClient(record: record, invocation: invocation, runtime: runtime, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
            }
        }
    }

    private func localZellijRuntime() throws -> LocalZellijRuntime {
        let registry = LocalTmuxSessionRegistry.live(
            directoryName: "local-zellij",
            overrideVariable: "CMUX_LOCAL_ZELLIJ_STATE_DIR"
        )
        try registry.ensureSecureStorage()
        let socketDirectory = registry.rootURL.appendingPathComponent("sock", isDirectory: true).path
        try ensurePrivateLocalZellijDirectory(socketDirectory)

        let environment = ProcessInfo.processInfo.environment
        let path: String?
        if let override = environment["CMUX_LOCAL_ZELLIJ_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            path = URL(fileURLWithPath: resolvePath(override)).standardizedFileURL.path
        } else {
            path = LocalTmuxExecutableResolver(executableName: "zellij").resolve(environmentPath: environment["PATH"])
        }
        var isDirectory = ObjCBool(false)
        guard let path,
              !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else {
            throw CLIError(message: String(localized: "cli.localZellij.error.zellijMissing", defaultValue: "local-zellij requires zellij. Install zellij or set CMUX_LOCAL_ZELLIJ_BIN to its path"), exitCode: 127)
        }
        let builder = LocalZellijCommandBuilder(zellijPath: path, socketDirectory: socketDirectory)
        guard builder.maxSessionNameBytes > 0 else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localZellij.error.socketPathTooLong", defaultValue: "local-zellij state directory is too long for a Unix socket: %@"),
                socketDirectory
            ))
        }
        let runner = LocalTmuxProcessRunner(
            executablePath: path,
            environment: builder.environment(base: environment),
            runFailedMessage: {
                String(localized: "cli.localZellij.error.runFailed", defaultValue: "local-zellij could not run zellij")
            },
            timedOutMessage: {
                String(localized: "cli.localZellij.error.timedOut", defaultValue: "local-zellij command timed out")
            }
        )
        return LocalZellijRuntime(registry: registry, builder: builder, runner: runner)
    }

    /// zellij's sockets are the access boundary for its sessions, so their
    /// directory must be a user-owned 0700 directory like the registry's.
    private func ensurePrivateLocalZellijDirectory(_ path: String) throws {
        let stateError = CLIError(message: String(localized: "cli.localZellij.error.stateOperationFailed", defaultValue: "local-zellij state could not be accessed safely"))
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            throw stateError
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            throw stateError
        }
    }

    private func startLocalZellijSession(
        invocation: LocalZellijInvocation,
        runtime: LocalZellijRuntime
    ) throws -> LocalTmuxSessionRecord {
        let builder = runtime.builder
        let name = try LocalZellijSessionNameValidator(maxNameBytes: builder.maxSessionNameBytes)
            .validate(invocation.name ?? "")
        let requestedCwd = try invocation.cwd.map { try localZellijWorkingDirectory($0) }
        let command = invocation.command.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let existingRecord = try runtime.registry.load().first { $0.name == name }
        let newRecord = LocalTmuxSessionRecord(name: name, socketPath: builder.socketDirectory, cwd: "")
        let zellijName = LocalZellijCommandBuilder.zellijSessionName(for: existingRecord ?? newRecord)

        if let existingRecord,
           let listed = try runtime.sessions().first(where: { $0.name == zellijName }) {
            if listed.exited {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localZellij.error.sessionExited", defaultValue: "local-zellij session %@ has exited; attach to resurrect it or close it first"),
                    name
                ))
            }
            if command != nil {
                throw CLIError(message: String(localized: "cli.localZellij.error.existingSessionCommand", defaultValue: "local-zellij session already exists; use attach or close it before supplying a new command"))
            }
            if let requestedCwd, requestedCwd != existingRecord.cwd {
                throw CLIError(message: String(localized: "cli.localZellij.error.existingSessionCwd", defaultValue: "local-zellij session already exists with a different working directory; use attach or close it first"))
            }
            var record = existingRecord
            record.socketPath = builder.socketDirectory
            record.updatedAt = Date.now.timeIntervalSince1970
            try runtime.registry.upsert(record)
            return record
        }

        let cwd = try requestedCwd ?? localZellijWorkingDirectory(nil)
        // Save the identity before creating the session. If creation succeeds
        // but its result can't be confirmed, a retry finds this record and the
        // same zellij name instead of starting a second session.
        var record = existingRecord ?? newRecord
        record.cwd = cwd
        record.socketPath = builder.socketDirectory
        record.updatedAt = Date.now.timeIntervalSince1970
        try runtime.registry.upsert(record)

        let layoutURL = try command.map { command in
            let url = runtime.registry.rootURL.appendingPathComponent(".layout-\(UUID().uuidString).kdl", isDirectory: false)
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(builder.commandLayout(command: command).utf8),
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            ) else {
                throw CLIError(message: String(localized: "cli.localZellij.error.stateOperationFailed", defaultValue: "local-zellij state could not be accessed safely"))
            }
            return url
        }
        // zellij reads the layout while creating the session.
        defer {
            if let layoutURL { try? FileManager.default.removeItem(at: layoutURL) }
        }
        let created = try runtime.runner.run(arguments: builder.createBackgroundArguments(
            sessionName: zellijName,
            workingDirectory: cwd,
            layoutPath: layoutURL?.path
        ))
        // A listing failure propagates and leaves the record for a retry.
        let isLive = try runtime.sessions().contains { $0.name == zellijName && !$0.exited }
        guard created.succeeded, isLive else {
            if existingRecord == nil, !isLive {
                // Nothing was started, so the new record has nothing to track.
                _ = try? runtime.registry.remove(id: record.id)
            }
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localZellij.error.startFailed", defaultValue: "local-zellij could not start session %@"),
                name
            ))
        }
        return record
    }

    private func localZellijWorkingDirectory(_ raw: String?) throws -> String {
        let candidate = resolvePath(raw ?? FileManager.default.currentDirectoryPath)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localZellij.error.cwdInvalid", defaultValue: "local-zellij working directory is not an accessible directory: %@"),
                candidate
            ))
        }
        return URL(fileURLWithPath: candidate).standardizedFileURL.path
    }

    /// Finds a registered session. Sessions started outside this profile are
    /// never adopted: without the record's token, a name alone cannot tell
    /// them apart from the user's other zellij sessions.
    private func requireLocalZellijRecord(
        _ invocation: LocalZellijInvocation,
        runtime: LocalZellijRuntime
    ) throws -> LocalTmuxSessionRecord {
        let records = try runtime.registry.load()
        if let id = invocation.id {
            guard let record = records.first(where: { $0.id == id }) else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localZellij.error.sessionIDNotFound", defaultValue: "local-zellij session not found for id %@"),
                    id.uuidString
                ))
            }
            return record
        }
        let name = try LocalZellijSessionNameValidator(maxNameBytes: runtime.builder.maxSessionNameBytes)
            .validate(invocation.name ?? "")
        guard let record = records.first(where: { $0.name == name }) else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localZellij.error.sessionNotFound", defaultValue: "local-zellij session not found: %@"),
                name
            ))
        }
        return record
    }

    /// Serializes start and close across processes. The registry lock covers a
    /// single record write; this lock also covers the zellij call before it,
    /// so a close cannot remove the record of a session a concurrent start
    /// just created under the same name.
    private func withLocalZellijLifecycleLock<T>(
        _ runtime: LocalZellijRuntime,
        _ body: () throws -> T
    ) throws -> T {
        let path = runtime.registry.rootURL.appendingPathComponent("lifecycle.lock", isDirectory: false).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw CLIError(message: String(localized: "cli.localZellij.error.stateOperationFailed", defaultValue: "local-zellij state could not be accessed safely"))
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CLIError(message: String(localized: "cli.localZellij.error.stateOperationFailed", defaultValue: "local-zellij state could not be accessed safely"))
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func attachLocalZellijClient(
        record: LocalTmuxSessionRecord,
        invocation: LocalZellijInvocation,
        runtime: LocalZellijRuntime,
        client: SocketClient?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let client else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localZellij.error.requiresApp", defaultValue: "local-zellij %@ requires a running cmux app; use --headless for a direct zellij client"),
                invocation.action.rawValue
            ))
        }
        try attachLocalPersistentSession(
            record: record,
            attachCommand: runtime.builder.attachCommand(
                sessionName: LocalZellijCommandBuilder.zellijSessionName(for: record)
            ),
            socketPath: runtime.builder.socketDirectory,
            request: invocation.attachRequest,
            profile: .localZellij,
            registry: runtime.registry,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }
}
