import Foundation

extension CMUXCLI {
    func listLocalZellijSessions(
        runtime: LocalZellijRuntime,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let records = try runtime.registry.load()
        let listed = try runtime.sessions()
        let registeredNames = Set(records.map(LocalZellijCommandBuilder.zellijSessionName(for:)))
        var rows: [[String: Any]] = records.map { record in
            let zellijName = LocalZellijCommandBuilder.zellijSessionName(for: record)
            let state = localZellijState(of: zellijName, in: listed)
            return [
                "id": record.id.uuidString,
                "session_name": record.name,
                "zellij_session_name": zellijName,
                "socket_path": runtime.builder.socketDirectory,
                "managed": true,
                "live": state == "live",
                "state": state,
                "workspace_id": record.workspaceID ?? NSNull(),
                "workspace_title": record.workspaceTitle ?? NSNull(),
                "cwd": record.cwd,
            ]
        }
        // Live sessions in the private socket directory without a record,
        // shown so they can be found and ended with zellij. Exited sessions
        // without a record come from the user's other zellij sessions.
        for session in listed where !session.exited && !registeredNames.contains(session.name) {
            rows.append([
                "id": NSNull(),
                "session_name": session.name,
                "zellij_session_name": session.name,
                "socket_path": runtime.builder.socketDirectory,
                "managed": false,
                "live": true,
                "state": "live",
                "workspace_id": NSNull(),
                "workspace_title": NSNull(),
                "cwd": NSNull(),
            ])
        }
        if jsonOutput {
            let payload: [String: Any] = [
                "sessions": rows,
                "socket_path": runtime.builder.socketDirectory,
                "count": rows.count,
            ]
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else if rows.isEmpty {
            print(String(localized: "cli.localZellij.output.noSessions", defaultValue: "No local zellij sessions"))
        } else {
            for row in rows {
                let rowText = String.localizedStringWithFormat(
                    String(localized: "cli.localZellij.output.sessionRow", defaultValue: "%@ [%@]"),
                    row["session_name"] as? String ?? "?",
                    localZellijDisplayState(row["state"] as? String ?? "unknown")
                )
                let idSuffix = (row["id"] as? String).map {
                    String.localizedStringWithFormat(
                        String(localized: "cli.localZellij.output.idSuffix", defaultValue: " id=%@"),
                        $0
                    )
                } ?? ""
                print(rowText + idSuffix)
            }
        }
    }

    func statusLocalZellijSession(
        record: LocalTmuxSessionRecord,
        runtime: LocalZellijRuntime,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let zellijName = LocalZellijCommandBuilder.zellijSessionName(for: record)
        let state = localZellijState(of: zellijName, in: try runtime.sessions())
        if jsonOutput {
            let payload: [String: Any] = [
                "id": record.id.uuidString,
                "session_name": record.name,
                "zellij_session_name": zellijName,
                "socket_path": runtime.builder.socketDirectory,
                "cwd": record.cwd,
                "workspace_id": record.workspaceID ?? NSNull(),
                "workspace_title": record.workspaceTitle ?? NSNull(),
                "surface_id": record.surfaceID ?? NSNull(),
                "live": state == "live",
                "state": state,
                "updated_at": record.updatedAt,
            ]
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.localZellij.output.status", defaultValue: "%@ [%@] socket=%@"),
                record.name,
                localZellijDisplayState(state),
                runtime.builder.socketDirectory
            ))
        }
    }

    /// Kills the session and deletes its resurrection entry, then forgets it.
    func closeLocalZellijSession(
        record: LocalTmuxSessionRecord,
        runtime: LocalZellijRuntime,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let zellijName = LocalZellijCommandBuilder.zellijSessionName(for: record)
        if try runtime.sessions().contains(where: { $0.name == zellijName }) {
            let result = try runtime.runner.run(
                arguments: runtime.builder.deleteSessionArguments(sessionName: zellijName)
            )
            let alreadyGone = result.stdout.contains("not found") || result.stderr.contains("not found")
            guard result.succeeded || alreadyGone else {
                throw CLIError(message: String(localized: "cli.localZellij.error.closeFailed", defaultValue: "local-zellij close failed"))
            }
        }
        _ = try runtime.registry.remove(id: record.id)
        if jsonOutput {
            let payload: [String: Any] = [
                "closed": true,
                "id": record.id.uuidString,
                "session_name": record.name,
                "socket_path": runtime.builder.socketDirectory,
            ]
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.localZellij.output.closed", defaultValue: "OK closed session=%@"),
                record.name
            ))
        }
    }

    /// Hands this terminal to a zellij client outside the cmux GUI.
    func runLocalZellijInteractiveAttach(
        record: LocalTmuxSessionRecord,
        runtime: LocalZellijRuntime
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.builder.zellijPath)
        process.arguments = runtime.builder.attachArguments(
            sessionName: LocalZellijCommandBuilder.zellijSessionName(for: record)
        )
        let environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("CMUX_") && !$0.key.hasPrefix("CMUXD_") }
        process.environment = runtime.builder.environment(base: environment)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError(message: String(localized: "cli.localZellij.error.interactiveStart", defaultValue: "local-zellij could not start an interactive client"), exitCode: 127)
        }
        guard process.terminationStatus == 0 else {
            throw CLIError(message: String(localized: "cli.localZellij.error.interactiveExit", defaultValue: "local-zellij interactive client exited with an error"), exitCode: process.terminationStatus)
        }
    }

    func printLocalZellijRecord(
        _ record: LocalTmuxSessionRecord,
        state: String,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            let payload: [String: Any] = [
                "id": record.id.uuidString,
                "session_name": record.name,
                "zellij_session_name": LocalZellijCommandBuilder.zellijSessionName(for: record),
                "socket_path": record.socketPath,
                "cwd": record.cwd,
                "state": state,
                "live": true,
            ]
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(String.localizedStringWithFormat(
                String(localized: "cli.localZellij.output.record", defaultValue: "OK session=%@ id=%@ state=%@ socket=%@"),
                record.name,
                record.id.uuidString,
                localZellijDisplayState(state),
                record.socketPath
            ))
        }
    }

    /// `live`, `exited` (zellij can resurrect it), or `stale` (gone).
    private func localZellijState(
        of name: String,
        in sessions: [LocalZellijSessionListParser.Session]
    ) -> String {
        guard let session = sessions.first(where: { $0.name == name }) else { return "stale" }
        return session.exited ? "exited" : "live"
    }

    private func localZellijDisplayState(_ state: String) -> String {
        switch state {
        case "live":
            return String(localized: "cli.localZellij.state.live", defaultValue: "live")
        case "exited":
            return String(localized: "cli.localZellij.state.exited", defaultValue: "exited")
        case "stale":
            return String(localized: "cli.localZellij.state.stale", defaultValue: "stale")
        case "detached":
            return String(localized: "cli.localZellij.state.detached", defaultValue: "detached")
        default:
            return String(localized: "cli.localZellij.state.unknown", defaultValue: "unknown")
        }
    }
}
