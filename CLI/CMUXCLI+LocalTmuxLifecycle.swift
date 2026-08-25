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
        var rows: [[String: Any]] = []
        for session in liveSessions {
            let record = records.first(where: { $0.name == session.name })
            rows.append([
                "id": record?.id.uuidString ?? NSNull(),
                "session_name": session.name,
                "session_id": session.tmuxID,
                "socket_path": builder.socketPath,
                "windows": session.windows,
                "created": session.created,
                "clients": clients.filter { $0.sessionName == session.name }.count,
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
            print("No local tmux sessions")
        } else {
            for row in rows {
                let name = row["session_name"] as? String ?? "?"
                let state = (row["live"] as? Bool) == true ? "live" : "stale"
                let clients = row["clients"] as? Int ?? 0
                let id = row["id"] as? String
                print("\(name) [\(state)] clients=\(clients)\(id.map { " id=\($0)" } ?? "")")
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
            print("\(record.name) [\(result.succeeded ? "live" : "stale")] clients=\(clients.count) socket=\(builder.socketPath)")
        }
    }

    func cleanupLocalTmuxSessions(
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        runner: LocalTmuxProcessRunner,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let listed = try runner.run(arguments: builder.listSessionsArguments())
        guard listed.succeeded else {
            let detail = listed.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = String(
                localized: "cli.localTmux.error.cleanupListFailed",
                defaultValue: "local-tmux cleanup could not list sessions; the registry was left unchanged."
            )
            throw CLIError(message: detail.isEmpty ? message : "\(message) \(detail)")
        }
        let liveNames = Set(parseLocalTmuxSessions(listed.stdout).map(\.name))
        let removed = try registry.remove { !liveNames.contains($0.name) }
        let payload: [String: Any] = [
            "removed": removed.map { $0.id.uuidString },
            "removed_names": removed.map(\.name),
            "socket_path": builder.socketPath,
        ]
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(removed.isEmpty ? "No stale local tmux sessions" : "Removed \(removed.count) stale local tmux session\(removed.count == 1 ? "" : "s")")
        }
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
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message: detail.isEmpty ? "local-tmux close failed" : "local-tmux close failed: \(detail)")
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
            print("OK closed session=\(record.name)")
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
                throw CLIError(message: "local-tmux client not found for session \(record.name): \(explicit)")
            }
            target = explicit
        } else {
            guard clients.count == 1, let only = clients.first else {
                if clients.isEmpty {
                    throw CLIError(message: "local-tmux session has no attached clients: \(record.name)")
                }
                throw CLIError(message: "local-tmux session has multiple clients; pass --client <id> or --all to detach explicitly")
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
            print(invocation.all ? "OK detached all clients from session=\(record.name)" : "OK detached session=\(record.name) client=\(target ?? "unknown")")
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
            throw CLIError(message: "local-tmux could not start an interactive client: \(error)", exitCode: 127)
        }
        guard process.terminationStatus == 0 else {
            throw CLIError(message: "local-tmux interactive client exited with status \(process.terminationStatus)", exitCode: process.terminationStatus)
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
            print("OK session=\(record.name) id=\(record.id.uuidString) state=\(state) socket=\(record.socketPath)")
        }
    }
}
