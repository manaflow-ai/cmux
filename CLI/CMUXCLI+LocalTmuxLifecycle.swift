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
        let result = try runner.run(arguments: builder.listSessionsArguments())
        let liveSessions = result.succeeded ? parseLocalTmuxSessions(result.stdout) : []
        let liveNames = Set(liveSessions.map(\.name))
        let clients = parseLocalTmuxClients(
            (try? runner.run(arguments: builder.listClientsArguments()).stdout) ?? ""
        )
        let recordsByName = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) })
        var clientCountsBySession: [String: Int] = [:]
        for client in clients {
            clientCountsBySession[client.sessionName, default: 0] += 1
        }
        var rows: [[String: Any]] = []
        for session in liveSessions {
            let record = recordsByName[session.name]
            rows.append([
                "id": record?.id.uuidString ?? NSNull(),
                "session_name": session.name,
                "session_id": session.tmuxID,
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
        for record in records where !liveNames.contains(record.name) {
            rows.append([
                "id": record.id.uuidString,
                "session_name": record.name,
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
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let result = try runner.run(arguments: builder.hasSessionArguments(record.name))
        let clients = result.succeeded
            ? parseLocalTmuxClients((try? runner.run(arguments: builder.listClientsArguments()).stdout) ?? "")
                .filter { $0.sessionName == record.name }
            : []
        var payload: [String: Any] = [
            "id": record.id.uuidString,
            "session_name": record.name,
            "socket_path": builder.socketPath,
            "cwd": record.cwd,
            "workspace_id": record.workspaceID ?? NSNull(),
            "workspace_title": record.workspaceTitle ?? NSNull(),
            "surface_id": record.surfaceID ?? NSNull(),
            "live": result.succeeded,
            "clients": clients.count,
            "updated_at": record.updatedAt,
        ]
        if !result.succeeded {
            payload["stale"] = true
        }
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.localTmux.output.status", defaultValue: "%@ [%@] clients=%lld socket=%@"),
                record.name,
                result.succeeded ? "live" : "stale",
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
        let listed = try runner.run(arguments: builder.listSessionsArguments())
        let liveNames: Set<String>
        if listed.succeeded {
            liveNames = Set(parseLocalTmuxSessions(listed.stdout).map(\.name))
        } else if localTmuxListingIndicatesStoppedServer(listed, builder: builder) {
            liveNames = []
        } else {
            let message = String(
                localized: "cli.localTmux.error.cleanupListFailed",
                defaultValue: "local-tmux cleanup could not list sessions; the registry was left unchanged."
            )
            throw CLIError(message: message)
        }
        let stale = records.filter { !liveNames.contains($0.name) }
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

    func closeLocalTmuxSession(
        record: LocalTmuxSessionRecord,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let result = try runner.run(arguments: builder.killSessionArguments(record.name))
        guard result.succeeded || result.stderr.localizedCaseInsensitiveContains("no server running") || result.stderr.localizedCaseInsensitiveContains("session not found") else {
            let message = String(localized: "cli.localTmux.error.closeFailed", defaultValue: "local-tmux close failed")
            throw CLIError(message: message)
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
        let listed = try runner.run(arguments: builder.listClientsArguments())
        let clients = parseLocalTmuxClients(listed.succeeded ? listed.stdout : "")
            .filter { $0.sessionName == record.name }
        let target: String?
        if invocation.all {
            target = nil
        } else if let explicit = invocation.clientID {
            guard clients.contains(where: { $0.clientID == explicit }) else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.clientNotFound", defaultValue: "local-tmux client not found for session %@: %@"),
                    record.name,
                    explicit
                ))
            }
            target = explicit
        } else {
            guard clients.count == 1, let only = clients.first else {
                if clients.isEmpty {
                    throw CLIError(message: String.localizedStringWithFormat(
                        String(localized: "cli.localTmux.error.noClients", defaultValue: "local-tmux session has no attached clients: %@"),
                        record.name
                    ))
                }
                throw CLIError(message: String(localized: "cli.localTmux.error.multipleClients", defaultValue: "local-tmux session has multiple clients; pass --client <id> or --all to detach explicitly"))
            }
            target = only.clientID
        }
        _ = try runner.requireSuccess(
            builder.detachArguments(sessionName: record.name, clientID: target, all: invocation.all),
            context: "detach"
        )
        var updated = record
        updated.updatedAt = Date().timeIntervalSince1970
        try registry.upsert(updated)
        let payload: [String: Any] = [
            "detached": true,
            "all": invocation.all,
            "client_id": target ?? NSNull(),
            "id": record.id.uuidString,
            "session_name": record.name,
        ]
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            if invocation.all {
                print(String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.output.detachedAll", defaultValue: "OK detached all clients from session=%@"),
                    record.name
                ))
            } else {
                print(String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.output.detached", defaultValue: "OK detached session=%@ client=%@"),
                    record.name,
                    target ?? "unknown"
                ))
            }
        }
    }

    func runLocalTmuxInteractiveAttach(
        record: LocalTmuxSessionRecord,
        builder: LocalTmuxCommandBuilder
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: builder.tmuxPath)
        process.arguments = builder.attachArguments(sessionName: record.name)
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

    private struct LocalTmuxSessionLine {
        let name: String
        let tmuxID: String
        let windows: Int
        let created: String
    }

    private struct LocalTmuxClientLine {
        let clientID: String
        let sessionName: String
        let pid: String
        let tty: String
    }

    private func parseLocalTmuxSessions(_ output: String) -> [LocalTmuxSessionLine] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty else { return nil }
            return LocalTmuxSessionLine(
                name: fields[0],
                tmuxID: fields[1],
                windows: Int(fields[2]) ?? 0,
                created: fields[3]
            )
        }
    }

    private func parseLocalTmuxClients(_ output: String) -> [LocalTmuxClientLine] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty else { return nil }
            return LocalTmuxClientLine(clientID: fields[0], sessionName: fields[1], pid: fields[2], tty: fields[3])
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
