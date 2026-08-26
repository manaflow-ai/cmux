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
                if invocation.headless {
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
            if invocation.headless {
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
            let record = LocalTmuxSessionRecord(name: validatedName, socketPath: builder.socketPath, cwd: FileManager.default.currentDirectoryPath)
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

    private func attachLocalTmuxSession(
        record originalRecord: LocalTmuxSessionRecord,
        invocation: LocalTmuxInvocation,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let live = try runner.run(arguments: builder.hasSessionArguments(originalRecord.name))
        guard live.succeeded else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localTmux.error.sessionNotRunning", defaultValue: "local-tmux session is no longer running: %@"),
                originalRecord.name
            ))
        }
        let workspace = try resolveLocalTmuxWorkspace(
            invocation: invocation,
            record: originalRecord,
            client: client
        )
        guard workspace.id != nil || (originalRecord.workspaceID == nil && originalRecord.workspaceTitle == nil) else {
            throw CLIError(message: String(localized: "cli.localTmux.error.workspaceNotFound", defaultValue: "local-tmux workspace target was not found"))
        }
        if !invocation.newClient,
           invocation.surface == nil,
           invocation.pane == nil,
           originalRecord.surfaceID != nil,
           let workspaceID = workspace.id,
           try findExistingLocalTmuxSurface(
               workspaceID: workspaceID,
               sessionName: originalRecord.name,
               persistedSurfaceID: originalRecord.surfaceID,
               client: client
           ) == nil {
            throw CLIError(message: String(localized: "cli.localTmux.error.surfaceNotFound", defaultValue: "local-tmux surface target was not found"))
        }
        let attachCommand = builder.attachCommand(sessionName: originalRecord.name)
        var payload: [String: Any]
        if !invocation.newClient,
           invocation.surface == nil,
           invocation.pane == nil,
           let workspaceID = workspace.id,
           let existingSurface = try findExistingLocalTmuxSurface(
               workspaceID: workspaceID,
               sessionName: originalRecord.name,
               persistedSurfaceID: originalRecord.surfaceID,
               client: client
           ),
           let isLive = try localTmuxSurfaceHasLiveClient(
               workspaceID: workspaceID,
               surfaceID: existingSurface,
               client: client
           ) {
            if isLive {
                payload = [
                    "workspace_id": workspaceID,
                    "surface_id": existingSurface,
                    "session_name": originalRecord.name,
                    "session_id": originalRecord.id.uuidString,
                    "socket_path": builder.socketPath,
                    "reattached": true,
                    "mode": "local-tmux",
                ]
                if invocation.focus ?? true {
                    let focused = try client.sendV2(method: "surface.focus", params: [
                        "workspace_id": workspaceID,
                        "surface_id": existingSurface,
                    ])
                    payload.merge(focused) { _, new in new }
                }
            } else {
                payload = try client.sendV2(method: "surface.respawn", params: [
                    "workspace_id": workspaceID,
                    "surface_id": existingSurface,
                    "command": attachCommand,
                    "initial_command": attachCommand,
                    "tmux_start_command": attachCommand,
                    "working_directory": originalRecord.cwd,
                    "focus": invocation.focus ?? true,
                ])
            }
        } else if let workspaceID = workspace.id {
            var params: [String: Any] = [
                "type": "terminal",
                "workspace_id": workspaceID,
                "initial_command": attachCommand,
                "tmux_start_command": attachCommand,
                "working_directory": originalRecord.cwd,
                "focus": invocation.focus ?? true,
            ]
            if let paneRaw = invocation.pane,
               let paneID = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceID) {
                params["pane_id"] = paneID
            } else if let paneRaw = invocation.pane {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.targetNotFound", defaultValue: "local-tmux could not resolve %@ target %@"),
                    "pane",
                    paneRaw
                ))
            }
            if let surfaceRaw = invocation.surface,
               let surfaceID = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceID) {
                params["surface_id"] = surfaceID
                params["command"] = attachCommand
                params.removeValue(forKey: "type")
                params.removeValue(forKey: "initial_command")
                payload = try client.sendV2(method: "surface.respawn", params: params)
            } else if let surfaceRaw = invocation.surface {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.targetNotFound", defaultValue: "local-tmux could not resolve %@ target %@"),
                    "surface",
                    surfaceRaw
                ))
            } else {
                payload = try client.sendV2(method: "surface.create", params: params)
            }
        } else {
            guard invocation.pane == nil, invocation.surface == nil else {
                throw CLIError(message: String(localized: "cli.localTmux.error.workspaceRequiredForTarget", defaultValue: "local-tmux pane or surface targets require a workspace"))
            }
            var createParams: [String: Any] = [
                "title": workspace.title ?? "tmux:\(originalRecord.name)",
                "cwd": originalRecord.cwd,
                "focus": invocation.focus ?? true,
            ]
            if let windowRaw = invocation.window,
               let windowID = try normalizeWindowHandle(windowRaw, client: client) {
                createParams["window_id"] = windowID
            }
            let created = try client.sendV2(method: "workspace.create", params: createParams)
            guard let workspaceID = created["workspace_id"] as? String,
                  let surfaceID = created["surface_id"] as? String else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.workspaceCreateFailed", defaultValue: "local-tmux could not create a workspace for %@"),
                    originalRecord.name
                ))
            }
            payload = try client.sendV2(method: "surface.respawn", params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "command": attachCommand,
                "initial_command": attachCommand,
                "tmux_start_command": attachCommand,
                "working_directory": originalRecord.cwd,
                "focus": invocation.focus ?? true,
            ])
            payload["workspace_id"] = workspaceID
        }

        let workspaceID = (payload["workspace_id"] as? String) ?? workspace.id
        let surfaceID = payload["surface_id"] as? String
        var updated = originalRecord
        updated.workspaceID = workspaceID
        updated.workspaceTitle = workspace.title
            ?? originalRecord.workspaceTitle
            ?? "tmux:\(originalRecord.name)"
        updated.surfaceID = surfaceID ?? originalRecord.surfaceID
        updated.updatedAt = Date().timeIntervalSince1970
        try registry.upsert(updated)

        payload["session_id"] = updated.id.uuidString
        payload["session_name"] = updated.name
        payload["socket_path"] = builder.socketPath
        payload["mode"] = "local-tmux"
        let fallback = String.localizedStringWithFormat(
            String(localized: "cli.localTmux.output.attached", defaultValue: "OK session=%@ surface=%@ mode=local-tmux"),
            updated.name,
            surfaceID ?? "unknown"
        )
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: fallback)
    }

    private func resolveLocalTmuxWorkspace(
        invocation: LocalTmuxInvocation,
        record: LocalTmuxSessionRecord,
        client: SocketClient
    ) throws -> (id: String?, title: String?, cwd: String?) {
        let windowID = try normalizeWindowHandle(invocation.window, client: client)
        if let rawWorkspace = invocation.workspace {
            guard let workspaceID = try normalizeWorkspaceHandle(rawWorkspace, client: client, windowHandle: windowID) else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.targetNotFound", defaultValue: "local-tmux could not resolve %@ target %@"),
                    "workspace",
                    rawWorkspace
                ))
            }
            let summary = try workspaceSummary(workspaceID: workspaceID, windowID: windowID, client: client, fallbackTitle: record.workspaceTitle, fallbackCwd: record.cwd)
            guard summary.id != nil else {
                throw CLIError(message: String(localized: "cli.localTmux.error.workspaceNotFound", defaultValue: "local-tmux workspace target was not found"))
            }
            return summary
        }
        if invocation.workspace == nil, invocation.window == nil,
           let caller = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"],
           let workspaceID = try normalizeWorkspaceHandle(caller, client: client) {
            let summary = try workspaceSummary(workspaceID: workspaceID, windowID: nil, client: client, fallbackTitle: record.workspaceTitle, fallbackCwd: record.cwd)
            guard summary.id != nil else {
                throw CLIError(message: String(localized: "cli.localTmux.error.workspaceNotFound", defaultValue: "local-tmux workspace target was not found"))
            }
            return summary
        }

        if let persistedWorkspaceID = record.workspaceID,
           let workspaceID = try normalizeWorkspaceHandle(persistedWorkspaceID, client: client) {
            let summary = try workspaceSummary(
                workspaceID: workspaceID,
                windowID: windowID,
                client: client,
                fallbackTitle: record.workspaceTitle,
                fallbackCwd: record.cwd
            )
            if summary.id != nil { return summary }
        }

        // Runtime IDs may be regenerated on relaunch. Match the durable hints
        // first, then fall back to the selected workspace only when no exact
        // candidate exists; never blindly trust the old ID.
        if let title = record.workspaceTitle, !title.isEmpty {
            let windows = try client.sendV2(method: "window.list")["windows"] as? [[String: Any]] ?? []
            var matches: [(String, String?, String?)] = []
            for window in windows {
                guard let windowID = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowID])
                for item in listed["workspaces"] as? [[String: Any]] ?? [] {
                    guard let id = item["id"] as? String,
                          (item["title"] as? String) == title else { continue }
                    let cwd = item["current_directory"] as? String
                    if record.cwd.isEmpty || cwd == record.cwd {
                        matches.append((id, title, cwd))
                    }
                }
            }
            if matches.count == 1 {
                return (matches[0].0, matches[0].1, matches[0].2)
            }
            if matches.count > 1 {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.multipleWorkspaces", defaultValue: "local-tmux found multiple workspaces named %@; pass --workspace to choose the reattach target"),
                    title
                ))
            }
        }
        guard record.workspaceID == nil, record.workspaceTitle == nil else {
            return (nil, record.workspaceTitle, record.cwd)
        }
        var currentParams: [String: Any] = [:]
        if let windowID { currentParams["window_id"] = windowID }
        if let current = try? client.sendV2(method: "workspace.current", params: currentParams),
           let workspaceID = current["workspace_id"] as? String {
            return try workspaceSummary(workspaceID: workspaceID, windowID: windowID, client: client, fallbackTitle: record.workspaceTitle, fallbackCwd: record.cwd)
        }
        return (nil, record.workspaceTitle, record.cwd)
    }

    private func workspaceSummary(
        workspaceID: String,
        windowID: String?,
        client: SocketClient,
        fallbackTitle: String?,
        fallbackCwd: String?
    ) throws -> (id: String?, title: String?, cwd: String?) {
        let response = try client.sendV2(
            method: "workspace.list",
            params: windowID.map { ["window_id": $0] } ?? [:]
        )
        if let item = (response["workspaces"] as? [[String: Any]])?.first(where: { ($0["id"] as? String) == workspaceID }) {
            return (workspaceID, item["title"] as? String ?? fallbackTitle, item["current_directory"] as? String ?? fallbackCwd)
        }
        return (nil, fallbackTitle, fallbackCwd)
    }

    private func findExistingLocalTmuxSurface(
        workspaceID: String,
        sessionName: String,
        persistedSurfaceID: String?,
        client: SocketClient
    ) throws -> String? {
        let response = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceID])
        let surfaces = response["surfaces"] as? [[String: Any]] ?? []
        let candidates = if let persistedSurfaceID {
            surfaces.filter { ($0["id"] as? String) == persistedSurfaceID }
        } else {
            surfaces
        }
        let marker = " -t '=\(sessionName)'"
        for surface in candidates {
            let initial = surface["initial_command"] as? String ?? ""
            let start = surface["tmux_start_command"] as? String ?? ""
            guard (initial.contains(LocalTmuxCommandBuilder.restoreMarker) || start.contains(LocalTmuxCommandBuilder.restoreMarker)),
                  initial.contains(marker) || start.contains(marker),
                  let id = surface["id"] as? String else { continue }
            return id
        }
        return nil
    }

    /// Checks the authoritative process tree before claiming a surface was
    /// reattached. A persisted marker alone can outlive a failed restore or a
    /// dead tmux client, so stale surfaces must take the respawn path.
    private func localTmuxSurfaceHasLiveClient(
        workspaceID: String,
        surfaceID: String,
        client: SocketClient
    ) throws -> Bool {
        let payload = try client.sendV2(
            method: "system.top",
            params: [
                "workspace_id": workspaceID,
                "include_processes": true,
            ],
            responseTimeout: 2.0
        )
        guard let windows = payload["windows"] as? [[String: Any]] else {
            throw CLIError(message: String(localized: "cli.localTmux.error.livenessUnavailable", defaultValue: "local-tmux could not verify the existing surface; no new client was created"))
        }
        for window in windows {
            for workspace in window["workspaces"] as? [[String: Any]] ?? [] {
                for pane in workspace["panes"] as? [[String: Any]] ?? [] {
                    for surface in pane["surfaces"] as? [[String: Any]] ?? [] {
                        guard (surface["id"] as? String) == surfaceID else { continue }
                        return localTmuxProcessTreeContainsTmux(
                            surface["processes"] as? [[String: Any]] ?? []
                        )
                    }
                }
            }
        }
        return false
    }

    private func localTmuxProcessTreeContainsTmux(_ processes: [[String: Any]]) -> Bool {
        for process in processes {
            let name = (process["name"] as? String)?.lowercased() ?? ""
            let path = (process["path"] as? String).map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""
            if name == "tmux" || name.hasPrefix("tmux:") || path == "tmux" {
                return true
            }
            if localTmuxProcessTreeContainsTmux(process["children"] as? [[String: Any]] ?? []) {
                return true
            }
        }
        return false
    }

}
