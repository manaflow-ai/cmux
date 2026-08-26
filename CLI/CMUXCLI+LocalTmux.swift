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
            let session = try startLocalTmuxSession(
                invocation: invocation,
                registry: registry,
                builder: builder,
                runner: runner
            )
            if invocation.detached || invocation.headless {
                if invocation.headless, !invocation.detached {
                    try runLocalTmuxInteractiveAttach(session: session, builder: builder)
                } else {
                    printLocalTmuxRecord(session.record, jsonOutput: jsonOutput, idFormat: idFormat, state: "detached")
                }
                return
            }
            try attachLocalTmuxSession(
                session: session,
                invocation: invocation,
                registry: registry,
                builder: builder,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        case .attach:
            let session = try requireOrDiscoverLocalTmuxSession(
                invocation,
                registry: registry,
                builder: builder,
                runner: runner
            )
            if invocation.headless {
                try runLocalTmuxInteractiveAttach(session: session, builder: builder)
                return
            }
            try attachLocalTmuxSession(
                session: session,
                invocation: invocation,
                registry: registry,
                builder: builder,
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
            let session = try startLocalTmuxSession(invocation: invocation, registry: registry, builder: builder, runner: runner)
            if invocation.headless, !invocation.detached {
                try runLocalTmuxInteractiveAttach(session: session, builder: builder)
            } else {
                printLocalTmuxRecord(session.record, jsonOutput: jsonOutput, idFormat: idFormat, state: "detached")
            }
        case .attach:
            let session = try requireOrDiscoverLocalTmuxSession(invocation, registry: registry, builder: builder, runner: runner)
            try runLocalTmuxInteractiveAttach(session: session, builder: builder)
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
            try statusLocalTmuxSession(record: record, registry: registry, builder: builder, runner: runner, jsonOutput: jsonOutput, idFormat: idFormat)
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
    ) throws -> LocalTmuxSessionIdentityResolver.LiveSession {
        guard let rawName = invocation.name else {
            throw CLIError(message: String(localized: "cli.localTmux.error.startRequiresName", defaultValue: "local-tmux start requires a session name"))
        }
        let name = try LocalTmuxSessionNameValidator().validate(rawName)
        let requestedCwd = try invocation.cwd.map { try localTmuxWorkingDirectory($0) }
        let identityResolver = LocalTmuxSessionIdentityResolver(
            registry: registry,
            builder: builder,
            runner: runner
        )
        let existing = try runner.run(arguments: builder.hasSessionArguments(name))
        if existing.succeeded {
            let observed = try identityResolver.observedSession(named: name)
            let existingPath = localTmuxSessionPath(
                identity: observed.binding.sessionID,
                builder: builder,
                runner: runner
            )
            if let requestedCwd,
               let existingPath,
               requestedCwd != existingPath {
                throw CLIError(message: String(localized: "cli.localTmux.error.existingSessionCwd", defaultValue: "local-tmux session already exists with a different working directory; use attach or close it first"))
            }
            if let command = invocation.command,
               !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CLIError(message: String(localized: "cli.localTmux.error.existingSessionCommand", defaultValue: "local-tmux session already exists; use attach or close it before supplying a new command"))
            }
            let records = try registry.load()
            if var record = records.first(where: { $0.tmuxBinding == observed.binding })
                ?? records.first(where: { $0.name == name }) {
                let liveSession = try identityResolver.bind(record, to: observed)
                record = liveSession.record
                if let sessionPath = existingPath {
                    record.cwd = sessionPath
                }
                record.socketPath = builder.socketPath
                record.updatedAt = Date.now.timeIntervalSince1970
                try registry.upsert(record)
                return .init(record: record, binding: observed.binding)
            }
            let sessionCwd = existingPath ?? ""
            let record = LocalTmuxSessionRecord(
                name: name,
                tmuxBinding: observed.binding,
                socketPath: builder.socketPath,
                cwd: sessionCwd
            )
            try registry.upsert(record)
            return .init(record: record, binding: observed.binding)
        }

        let cwd = try requestedCwd ?? localTmuxWorkingDirectory(nil)
        _ = try runner.requireSuccess(
            builder.newSessionArguments(sessionName: name, workingDirectory: cwd, command: invocation.command),
            context: "start"
        )
        let observed = try identityResolver.observedSession(named: name)
        // tmux owns scrollback for this profile; keep a useful bounded history
        // rather than inheriting a small user/global default.
        _ = try? runner.requireSuccess(
            builder.historyLimitArguments(binding: observed.binding),
            context: "configure history"
        )
        try registry.validateServerSocketIfPresent()
        let record = LocalTmuxSessionRecord(
            name: name,
            tmuxBinding: observed.binding,
            socketPath: builder.socketPath,
            cwd: cwd
        )
        try registry.upsert(record)
        return .init(record: record, binding: observed.binding)
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
        identity: LocalTmuxSessionIdentity,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner
    ) -> String? {
        guard let result = try? runner.run(arguments: builder.sessionPathArguments(sessionID: identity)),
              result.succeeded,
              !result.stdoutWasTruncated else { return nil }
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
            refreshed.updatedAt = Date.now.timeIntervalSince1970
            try registry.upsert(refreshed)
            return refreshed
        }
        if let name = invocation.name,
           let validatedName = try? LocalTmuxSessionNameValidator().validate(name),
           let record = records.first(where: { $0.name == validatedName }) {
            if record.socketPath == builder.socketPath { return record }
            var refreshed = record
            refreshed.socketPath = builder.socketPath
            refreshed.updatedAt = Date.now.timeIntervalSince1970
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
            let identityResolver = LocalTmuxSessionIdentityResolver(
                registry: registry,
                builder: builder,
                runner: runner
            )
            let observed = try identityResolver.observedSession(named: validatedName)
            let sessionCwd = localTmuxSessionPath(
                identity: observed.binding.sessionID,
                builder: builder,
                runner: runner
            ) ?? ""
            if var record = records.first(where: { $0.tmuxBinding == observed.binding }) {
                let liveSession = try identityResolver.bind(record, to: observed)
                record = liveSession.record
                record.socketPath = builder.socketPath
                if !sessionCwd.isEmpty { record.cwd = sessionCwd }
                record.updatedAt = Date.now.timeIntervalSince1970
                try registry.upsert(record)
                return record
            }
            let record = LocalTmuxSessionRecord(
                name: validatedName,
                tmuxBinding: observed.binding,
                socketPath: builder.socketPath,
                cwd: sessionCwd
            )
            try registry.upsert(record)
            return record
        }
        throw CLIError(message: String.localizedStringWithFormat(
            String(localized: "cli.localTmux.error.sessionIDNotFound", defaultValue: "local-tmux session not found for id %@"),
            invocation.id?.uuidString ?? "unknown"
        ))
    }

    private func requireOrDiscoverLocalTmuxSession(
        _ invocation: LocalTmuxInvocation,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner
    ) throws -> LocalTmuxSessionIdentityResolver.LiveSession {
        let record = try requireLocalTmuxRecord(
            invocation,
            registry: registry,
            runner: runner,
            builder: builder
        )
        return try LocalTmuxSessionIdentityResolver(
            registry: registry,
            builder: builder,
            runner: runner
        ).requireLive(record)
    }

}
