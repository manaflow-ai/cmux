import Darwin
import Foundation

extension CMUXCLI {
    /// Runs the opt-in local tmux profile. The ordinary terminal path never
    /// enters this method: a managed terminal is explicitly marked in both the
    /// tmux command and cmux's persisted `tmuxStartCommand` field.
    func runLocalTmuxCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String? = nil
    ) throws {
        var effectiveArguments = commandArgs
        if let windowOverride,
           !commandArgs.contains("--window"),
           !commandArgs.contains(where: { $0.hasPrefix("--window=") }) {
            effectiveArguments.append(contentsOf: ["--window", windowOverride])
        }
        let invocation = try LocalTmuxInvocation.parse(effectiveArguments)
        let registry = LocalTmuxSessionRegistry.live()
        let (_, builder, runner) = try localTmuxRuntime(registry: registry)
        if try runLocalTmuxLifecycleAction(
            invocation,
            registry: registry,
            builder: builder,
            runner: runner,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        ) {
            return
        }

        switch invocation.action {
        case .list, .status, .cleanup, .close, .detach:
            return
        case .start:
            let record = try startLocalTmuxSession(
                invocation: invocation,
                registry: registry,
                builder: builder,
                runner: runner
            )
            if invocation.detached || invocation.headless {
                if invocation.headless, !invocation.detached {
                    try runLocalTmuxInteractiveAttach(record: record, builder: builder)
                } else {
                    printLocalTmuxRecord(record, jsonOutput: jsonOutput, idFormat: idFormat, state: "detached")
                }
                return
            }
            try attachLocalTmuxSession(
                record: record,
                invocation: invocation,
                registry: registry,
                builder: builder,
                runner: runner,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        case .attach:
            let record = try requireOrDiscoverLocalTmuxRecord(
                invocation,
                registry: registry,
                builder: builder,
                runner: runner
            )
            if invocation.headless {
                try runLocalTmuxInteractiveAttach(record: record, builder: builder)
                return
            }
            try attachLocalTmuxSession(
                record: record,
                invocation: invocation,
                registry: registry,
                builder: builder,
                runner: runner,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        }

    }

    /// Dispatches operations that intentionally do not require a cmux GUI.
    /// This is called before socket discovery so a headless client can inspect,
    /// clean up, or detach a session while the app is quit or being updated.
    func runLocalTmuxOfflineCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let invocation = try LocalTmuxInvocation.parse(commandArgs)
        guard invocation.canRunWithoutCmux else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localTmux.error.requiresApp", defaultValue: "local-tmux %@ requires a running cmux app; use --headless for a direct tmux client"),
                invocation.action.rawValue
            ))
        }
        let registry = LocalTmuxSessionRegistry.live()
        let (_, builder, runner) = try localTmuxRuntime(registry: registry)
        _ = try runLocalTmuxLifecycleAction(
            invocation,
            registry: registry,
            builder: builder,
            runner: runner,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
        switch invocation.action {
        case .list, .status, .cleanup, .close, .detach:
            return
        case .start:
            let record = try startLocalTmuxSession(invocation: invocation, registry: registry, builder: builder, runner: runner)
            if invocation.headless, !invocation.detached {
                try runLocalTmuxInteractiveAttach(record: record, builder: builder)
            } else {
                printLocalTmuxRecord(record, jsonOutput: jsonOutput, idFormat: idFormat, state: "detached")
            }
        case .attach:
            let record = try requireOrDiscoverLocalTmuxRecord(invocation, registry: registry, builder: builder, runner: runner)
            try runLocalTmuxInteractiveAttach(record: record, builder: builder)
        }
    }

    /// Executes lifecycle actions shared by GUI and headless entry points.
    /// Returns `true` when the action was handled; start/attach remain in the
    /// caller because only the GUI path can supply an authenticated client.
    private func runLocalTmuxLifecycleAction(
        _ invocation: LocalTmuxInvocation,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws -> Bool {
        switch invocation.action {
        case .list:
            try listLocalTmuxSessions(registry: registry, builder: builder, runner: runner, jsonOutput: jsonOutput, idFormat: idFormat)
        case .status:
            let record = try requireLocalTmuxRecord(invocation, registry: registry, runner: runner, builder: builder)
            try statusLocalTmuxSession(record: record, builder: builder, runner: runner, jsonOutput: jsonOutput, idFormat: idFormat)
        case .cleanup:
            try cleanupLocalTmuxSessions(registry: registry, builder: builder, runner: runner, prune: invocation.prune, jsonOutput: jsonOutput, idFormat: idFormat)
        case .close:
            let record = try requireLocalTmuxRecord(invocation, registry: registry, runner: runner, builder: builder)
            try closeLocalTmuxSession(record: record, registry: registry, builder: builder, runner: runner, jsonOutput: jsonOutput, idFormat: idFormat)
        case .detach:
            let record = try requireLocalTmuxRecord(invocation, registry: registry, runner: runner, builder: builder)
            try detachLocalTmuxSession(record: record, invocation: invocation, registry: registry, builder: builder, runner: runner, jsonOutput: jsonOutput, idFormat: idFormat)
        case .start, .attach:
            return false
        }
        return true
    }

    private func localTmuxRuntime(
        registry: LocalTmuxSessionRegistry
    ) throws -> (path: String, builder: LocalTmuxCommandBuilder, runner: LocalTmuxProcessRunner) {
        try registry.ensureSecureStorage()
        try registry.validateServerSocketIfPresent()
        let environment = ProcessInfo.processInfo.environment
        let path: String?
        if let override = environment["CMUX_LOCAL_TMUX_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            path = URL(fileURLWithPath: resolvePath(override)).standardizedFileURL.path
        } else {
            path = LocalTmuxExecutableResolver().resolve(environmentPath: environment["PATH"])
        }
        guard let path, FileManager.default.isExecutableFile(atPath: path) else {
            throw CLIError(message: String(localized: "cli.localTmux.error.tmuxMissing", defaultValue: "local-tmux requires tmux. Install tmux or configure an executable tmux path"), exitCode: 127)
        }
        let socketPath = registry.serverSocketURL.path
        guard socketPath.utf8.count < 100 else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localTmux.error.socketPathTooLong", defaultValue: "local-tmux state directory is too long for a Unix socket: %@"),
                socketPath
            ))
        }
        let builder = LocalTmuxCommandBuilder(tmuxPath: path, socketPath: socketPath)
        return (path, builder, LocalTmuxProcessRunner(executablePath: path))
    }

    private func startLocalTmuxSession(
        invocation: LocalTmuxInvocation,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner
    ) throws -> LocalTmuxSessionRecord {
        guard let rawName = invocation.name else {
            throw CLIError(message: String(localized: "cli.localTmux.error.startRequiresName", defaultValue: "local-tmux start requires a session name"))
        }
        let name = try LocalTmuxSessionNameValidator().validate(rawName)
        let cwd = try localTmuxWorkingDirectory(invocation.cwd)
        let existing = try runner.run(arguments: builder.hasSessionArguments(name))
        if existing.succeeded {
            let existingPath = localTmuxSessionPath(name: name, builder: builder, runner: runner)
            if let requestedCwd = invocation.cwd,
               let existingPath,
               URL(fileURLWithPath: resolvePath(requestedCwd)).standardizedFileURL.path != existingPath {
                throw CLIError(message: String(localized: "cli.localTmux.error.existingSessionCwd", defaultValue: "local-tmux session already exists with a different working directory; use attach or close it first"))
            }
            if let command = invocation.command,
               !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CLIError(message: String(localized: "cli.localTmux.error.existingSessionCommand", defaultValue: "local-tmux session already exists; use attach or close it before supplying a new command"))
            }
            if var record = try registry.load().first(where: { $0.name == name }) {
                if let sessionPath = existingPath {
                    record.cwd = sessionPath
                }
                record.socketPath = builder.socketPath
                record.updatedAt = Date().timeIntervalSince1970
                try registry.upsert(record)
                return record
            }
            let sessionCwd = localTmuxSessionPath(name: name, builder: builder, runner: runner) ?? ""
            let record = LocalTmuxSessionRecord(name: name, socketPath: builder.socketPath, cwd: sessionCwd)
            try registry.upsert(record)
            return record
        }

        _ = try runner.requireSuccess(
            builder.newSessionArguments(sessionName: name, workingDirectory: cwd, command: invocation.command),
            context: "start"
        )
        // tmux owns scrollback for this profile; keep a useful bounded history
        // rather than inheriting a small user/global default.
        _ = try? runner.requireSuccess(
            builder.historyLimitArguments(sessionName: name),
            context: "configure history"
        )
        try registry.validateServerSocketIfPresent()
        let record = LocalTmuxSessionRecord(name: name, socketPath: builder.socketPath, cwd: cwd)
        try registry.upsert(record)
        return record
    }

    private func localTmuxWorkingDirectory(_ raw: String?) throws -> String {
        let candidate = resolvePath(raw ?? FileManager.default.currentDirectoryPath)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localTmux.error.cwdInvalid", defaultValue: "local-tmux working directory is not an accessible directory: %@"),
                candidate
            ))
        }
        return URL(fileURLWithPath: candidate).standardizedFileURL.path
    }

    private func localTmuxSessionPath(
        name: String,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner
    ) -> String? {
        guard let result = try? runner.run(arguments: builder.sessionPathArguments(name)),
              result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func requireLocalTmuxRecord(
        _ invocation: LocalTmuxInvocation,
        registry: LocalTmuxSessionRegistry,
        runner: LocalTmuxProcessRunner,
        builder: LocalTmuxCommandBuilder
    ) throws -> LocalTmuxSessionRecord {
        let records = try registry.load()
        if let id = invocation.id, let record = records.first(where: { $0.id == id }) {
            if record.socketPath == builder.socketPath { return record }
            var refreshed = record
            refreshed.socketPath = builder.socketPath
            refreshed.updatedAt = Date().timeIntervalSince1970
            try registry.upsert(refreshed)
            return refreshed
        }
        if let name = invocation.name,
           let validatedName = try? LocalTmuxSessionNameValidator().validate(name),
           let record = records.first(where: { $0.name == validatedName }) {
            if record.socketPath == builder.socketPath { return record }
            var refreshed = record
            refreshed.socketPath = builder.socketPath
            refreshed.updatedAt = Date().timeIntervalSince1970
            try registry.upsert(refreshed)
            return refreshed
        }
        if let name = invocation.name {
            let validatedName = try LocalTmuxSessionNameValidator().validate(name)
            let checked = try runner.run(arguments: builder.hasSessionArguments(validatedName))
            guard checked.succeeded else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.sessionNotFound", defaultValue: "local-tmux session not found: %@"),
                    validatedName
                ))
            }
            let sessionCwd = localTmuxSessionPath(name: validatedName, builder: builder, runner: runner) ?? ""
            let record = LocalTmuxSessionRecord(name: validatedName, socketPath: builder.socketPath, cwd: sessionCwd)
            try registry.upsert(record)
            return record
        }
        throw CLIError(message: String.localizedStringWithFormat(
            String(localized: "cli.localTmux.error.sessionIDNotFound", defaultValue: "local-tmux session not found for id %@"),
            invocation.id?.uuidString ?? "unknown"
        ))
    }

    private func requireOrDiscoverLocalTmuxRecord(
        _ invocation: LocalTmuxInvocation,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner
    ) throws -> LocalTmuxSessionRecord {
        try requireLocalTmuxRecord(invocation, registry: registry, runner: runner, builder: builder)
    }

}
