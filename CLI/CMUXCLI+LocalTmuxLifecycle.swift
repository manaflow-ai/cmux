import Foundation

extension CMUXCLI {
    func listLocalTmuxSessions(
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let records = try registry.load()
        let identityResolver = LocalTmuxSessionIdentityResolver(
            registry: registry,
            builder: builder,
            runner: runner
        )
        var result = try runner.run(arguments: builder.listSessionsArguments())
        if result.succeeded,
           !result.stdoutWasTruncated,
           !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try identityResolver.ensureServerIdentity()
            result = try runner.run(arguments: builder.listSessionsArguments())
        }
        let liveSessions = try localTmuxSessionLines(
            result,
            builder: builder,
            failureMessage: String(
                localized: "cli.localTmux.error.listFailed",
                defaultValue: "local-tmux could not list sessions; liveness is unknown."
            )
        )
        let clients: [LocalTmuxSessionListParser.ClientLine]
        if liveSessions.isEmpty {
            clients = []
        } else {
            clients = try localTmuxClientLines(
                runner.run(arguments: builder.listClientsArguments())
            )
        }
        let managedRecords = try LocalTmuxSessionReconciler(
            identityResolver: identityResolver
        ).managedRecords(records: records, liveSessions: liveSessions)
        let managedRecordIDs = Set(managedRecords.values.map(\.id))
        var clientCountsBySession: [String: Int] = [:]
        for client in clients {
            clientCountsBySession[client.sessionName, default: 0] += 1
        }
        var rows: [[String: Any]] = []
        for session in liveSessions {
            let record = managedRecords[session.binding]
            rows.append([
                "id": record?.id.uuidString ?? NSNull(),
                "session_name": session.name,
                "session_id": session.identity.rawValue,
                "socket_path": builder.socketPath,
                "windows": session.windows,
                "created": session.created,
                "clients": clientCountsBySession[session.name] ?? 0,
                "managed": record != nil,
                "workspace_id": record?.workspaceID ?? NSNull(),
                "workspace_title": record?.workspaceTitle ?? NSNull(),
                "cwd": record?.cwd ?? NSNull(),
                "live": true,
            ])
        }
        for record in records where !managedRecordIDs.contains(record.id) {
            rows.append([
                "id": record.id.uuidString,
                "session_name": record.name,
                "session_id": record.tmuxBinding?.sessionID.rawValue ?? NSNull(),
                "socket_path": builder.socketPath,
                "managed": true,
                "workspace_id": record.workspaceID ?? NSNull(),
                "workspace_title": record.workspaceTitle ?? NSNull(),
                "cwd": record.cwd,
                "live": false,
                "stale": true,
            ])
        }
        let payload: [String: Any] = [
            "sessions": rows,
            "socket_path": builder.socketPath,
            "count": rows.count,
        ]
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else if rows.isEmpty {
            print(String(localized: "cli.localTmux.output.noSessions", defaultValue: "No local tmux sessions"))
        } else {
            for row in rows {
                let name = row["session_name"] as? String ?? "?"
                let state = (row["live"] as? Bool) == true ? "live" : "stale"
                let clients = row["clients"] as? Int ?? 0
                let id = row["id"] as? String
                let rowText = String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.output.sessionRow", defaultValue: "%@ [%@] clients=%lld"),
                    name,
                    state,
                    clients
                )
                print(rowText + (id.map { " id=\($0)" } ?? ""))
            }
        }
    }

    func statusLocalTmuxSession(
        record: LocalTmuxSessionRecord,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let resolution = try LocalTmuxSessionIdentityResolver(
            registry: registry,
            builder: builder,
            runner: runner
        ).resolve(record)
        let liveSession: LocalTmuxSessionIdentityResolver.LiveSession?
        let clients: [LocalTmuxSessionListParser.ClientLine]
        switch resolution {
        case let .live(session):
            liveSession = session
            clients = try localTmuxClientLines(
                runner.run(arguments: builder.listClientsArguments(binding: session.binding))
            )
        case .stopped:
            liveSession = nil
            clients = []
        }
        let effectiveRecord = liveSession?.record ?? record
        var payload: [String: Any] = [
            "id": effectiveRecord.id.uuidString,
            "session_name": effectiveRecord.name,
            "socket_path": builder.socketPath,
            "cwd": effectiveRecord.cwd,
            "workspace_id": effectiveRecord.workspaceID ?? NSNull(),
            "workspace_title": effectiveRecord.workspaceTitle ?? NSNull(),
            "surface_id": effectiveRecord.surfaceID ?? NSNull(),
            "tmux_session_id": liveSession?.identity.rawValue
                ?? effectiveRecord.tmuxBinding?.sessionID.rawValue
                ?? NSNull(),
            "live": liveSession != nil,
            "clients": clients.count,
            "updated_at": effectiveRecord.updatedAt,
        ]
        if liveSession == nil {
            payload["stale"] = true
        }
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.localTmux.output.status", defaultValue: "%@ [%@] clients=%lld socket=%@"),
                effectiveRecord.name,
                liveSession != nil ? "live" : "stale",
                clients.count,
                builder.socketPath
            ))
        }
    }

    func cleanupLocalTmuxSessions(
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        prune: Bool,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let records = try registry.load()
        let identityResolver = LocalTmuxSessionIdentityResolver(
            registry: registry,
            builder: builder,
            runner: runner
        )
        var listed = try runner.run(arguments: builder.listSessionsArguments())
        if listed.succeeded,
           !listed.stdoutWasTruncated,
           !listed.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try identityResolver.ensureServerIdentity()
            listed = try runner.run(arguments: builder.listSessionsArguments())
        }
        let liveSessions = try localTmuxSessionLines(
            listed,
            builder: builder,
            failureMessage: String(
                localized: "cli.localTmux.error.cleanupListFailed",
                defaultValue: "local-tmux cleanup could not list sessions; the registry was left unchanged."
            )
        )
        let managedRecords = try LocalTmuxSessionReconciler(
            identityResolver: identityResolver
        ).managedRecords(records: records, liveSessions: liveSessions)
        let managedRecordIDs = Set(managedRecords.values.map(\.id))
        let stale = records.filter { !managedRecordIDs.contains($0.id) }
        let staleIDs = Set(stale.map(\.id))
        let removed = prune
            ? try registry.remove { staleIDs.contains($0.id) }
            : []
        let payload: [String: Any] = [
            "prune": prune,
            "stale": stale.map { $0.id.uuidString },
            "stale_names": stale.map(\.name),
            "removed": removed.map { $0.id.uuidString },
            "removed_names": removed.map(\.name),
            "socket_path": builder.socketPath,
        ]
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            if stale.isEmpty {
                print(String(localized: "cli.localTmux.output.noStale", defaultValue: "No stale local tmux sessions"))
            } else if prune {
                print(String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.output.removedStale", defaultValue: "Removed %lld stale local tmux session(s)"),
                    removed.count
                ))
            } else {
                print(String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.output.foundStale", defaultValue: "Found %lld stale local tmux session(s); pass --prune to remove them"),
                    stale.count
                ))
            }
        }
    }

    private func localTmuxListingIndicatesStoppedServer(
        _ result: LocalTmuxProcessResult,
        builder: LocalTmuxCommandBuilder
    ) -> Bool {
        let detail = result.stderr.lowercased()
        if detail.contains("no server running")
            || (detail.contains("error connecting") && detail.contains("no such file or directory")) {
            return true
        }
        guard detail.contains("error connecting"), detail.contains("connection refused") else {
            return false
        }
        var info = stat()
        return lstat(builder.socketPath, &info) == 0
            && info.st_uid == getuid()
            && info.st_mode & 0o077 == 0
    }

    private func localTmuxSessionLines(
        _ result: LocalTmuxProcessResult,
        builder: LocalTmuxCommandBuilder,
        failureMessage: String
    ) throws -> [LocalTmuxSessionListParser.SessionLine] {
        if result.succeeded {
            guard !result.stdoutWasTruncated else {
                throw CLIError(message: String(
                    localized: "cli.localTmux.error.listingIncomplete",
                    defaultValue: "local-tmux session listing was incomplete; liveness is unknown."
                ))
            }
            return try LocalTmuxSessionListParser().sessions(result.stdout)
        }
        if !result.stderrWasTruncated,
           localTmuxListingIndicatesStoppedServer(result, builder: builder) {
            return []
        }
        throw CLIError(message: failureMessage)
    }

    private func localTmuxClientLines(
        _ result: LocalTmuxProcessResult
    ) throws -> [LocalTmuxSessionListParser.ClientLine] {
        guard result.succeeded, !result.stdoutWasTruncated else {
            throw CLIError(message: String(
                localized: "cli.localTmux.error.clientListFailed",
                defaultValue: "local-tmux could not inspect attached clients."
            ))
        }
        return try LocalTmuxSessionListParser().clients(result.stdout)
    }

    func closeLocalTmuxSession(
        record: LocalTmuxSessionRecord,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let resolution = try LocalTmuxSessionIdentityResolver(
            registry: registry,
            builder: builder,
            runner: runner
        ).resolve(record)
        if case let .live(session) = resolution {
            let result = try runner.run(arguments: builder.killSessionArguments(binding: session.binding))
            guard result.succeeded
                || result.stderr.localizedCaseInsensitiveContains("no server running")
                || result.stderr.localizedCaseInsensitiveContains("session not found") else {
                let message = String(localized: "cli.localTmux.error.closeFailed", defaultValue: "local-tmux close failed")
                throw CLIError(message: message)
            }
        }
        _ = try registry.remove(id: record.id)
        let payload: [String: Any] = [
            "closed": true,
            "id": record.id.uuidString,
            "session_name": record.name,
            "socket_path": builder.socketPath,
        ]
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.localTmux.output.closed", defaultValue: "OK closed session=%@"),
                record.name
            ))
        }
    }

    func detachLocalTmuxSession(
        record: LocalTmuxSessionRecord,
        invocation: LocalTmuxInvocation,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let session = try LocalTmuxSessionIdentityResolver(
            registry: registry,
            builder: builder,
            runner: runner
        ).requireLive(record)
        let listed = try runner.run(arguments: builder.listClientsArguments(binding: session.binding))
        let clients = try localTmuxClientLines(listed)
        let target: String?
        if invocation.all {
            target = nil
        } else if let explicit = invocation.clientID {
            guard clients.contains(where: { $0.clientID == explicit }) else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.clientNotFound", defaultValue: "local-tmux client not found for session %@: %@"),
                    session.record.name,
                    explicit
                ))
            }
            target = explicit
        } else {
            guard clients.count == 1, let only = clients.first else {
                if clients.isEmpty {
                    throw CLIError(message: String.localizedStringWithFormat(
                        String(localized: "cli.localTmux.error.noClients", defaultValue: "local-tmux session has no attached clients: %@"),
                        session.record.name
                    ))
                }
                throw CLIError(message: String(localized: "cli.localTmux.error.multipleClients", defaultValue: "local-tmux session has multiple clients; pass --client <id> or --all to detach explicitly"))
            }
            target = only.clientID
        }
        _ = try runner.requireSuccess(
            builder.detachArguments(binding: session.binding, clientID: target),
            context: "detach"
        )
        var updated = session.record
        updated.updatedAt = Date.now.timeIntervalSince1970
        try registry.upsert(updated)
        let payload: [String: Any] = [
            "detached": true,
            "all": invocation.all,
            "client_id": target ?? NSNull(),
            "id": session.record.id.uuidString,
            "session_name": session.record.name,
        ]
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            if invocation.all {
                print(String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.output.detachedAll", defaultValue: "OK detached all clients from session=%@"),
                    session.record.name
                ))
            } else {
                print(String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.output.detached", defaultValue: "OK detached session=%@ client=%@"),
                    session.record.name,
                    target ?? "unknown"
                ))
            }
        }
    }

    func runLocalTmuxInteractiveAttach(
        session: LocalTmuxSessionIdentityResolver.LiveSession,
        builder: LocalTmuxCommandBuilder
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: builder.tmuxPath)
        process.arguments = builder.attachArguments(binding: session.binding)
        var environment = ProcessInfo.processInfo.environment
        environment = environment.filter { !$0.key.hasPrefix("CMUX_") && !$0.key.hasPrefix("CMUXD_") }
        environment.removeValue(forKey: "TMUX")
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            let message = String(localized: "cli.localTmux.error.interactiveStart", defaultValue: "local-tmux could not start an interactive client")
            throw CLIError(message: message, exitCode: 127)
        }
        guard process.terminationStatus == 0 else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localTmux.error.interactiveExit", defaultValue: "local-tmux interactive client exited with status %d"),
                process.terminationStatus
            ), exitCode: process.terminationStatus)
        }
    }

    func printLocalTmuxRecord(
        _ record: LocalTmuxSessionRecord,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        state: String
    ) {
        let payload: [String: Any] = [
            "id": record.id.uuidString,
            "session_name": record.name,
            "socket_path": record.socketPath,
            "cwd": record.cwd,
            "state": state,
            "live": true,
        ]
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.localTmux.output.record", defaultValue: "OK session=%@ id=%@ state=%@ socket=%@"),
                record.name,
                record.id.uuidString,
                state,
                record.socketPath
            ))
        }
    }
}
