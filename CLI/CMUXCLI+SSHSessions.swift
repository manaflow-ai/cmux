import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - SSH session list/cleanup/attach
extension CMUXCLI {
    func runSSHSessionList(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let allWorkspaces = rem0.contains("--all-workspaces")
        let remaining = rem0.filter { $0 != "--all-workspaces" }
        if let unknown = remaining.first(where: { Self.isFlagToken($0) }) {
            throw CLIError(message: "ssh-session-list: unknown flag '\(unknown)'. Known flags: --workspace <workspace>, --all-workspaces")
        }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux ssh-session-list [--workspace <workspace> | --all-workspaces]")
        }
        if allWorkspaces, workspaceOpt != nil {
            throw CLIError(message: "ssh-session-list: --all-workspaces cannot be combined with --workspace")
        }

        let params = try sshSessionTargetParams(
            commandName: "ssh-session-list",
            workspaceOpt: workspaceOpt,
            allWorkspaces: allWorkspaces,
            client: client
        )

        let response = try client.sendV2(method: "workspace.remote.pty_sessions", params: params)
        let sessions = response["sessions"] as? [[String: Any]] ?? []
        let errors = response["errors"] as? [[String: Any]] ?? []
        if jsonOutput {
            print(jsonString(formatIDs(response, mode: idFormat)))
            if !errors.isEmpty {
                throw CLIError(message: sshSessionListFailureMessage(errors))
            }
            return
        }

        if sessions.isEmpty, errors.isEmpty {
            print("No persisted SSH PTY sessions")
            return
        }
        for session in sessions {
            let sessionID = (session["session_id"] as? String) ?? "unknown"
            let workspaceLabel = debugString(session["workspace_ref"])
                ?? (debugString(session["workspace_id"])?.prefix(8).description)
                ?? "workspace:?"
            let workspaceTitle = debugString(session["workspace_title"]) ?? ""
            let effectiveCols = debugString(session["effective_cols"]) ?? "?"
            let effectiveRows = debugString(session["effective_rows"]) ?? "?"
            let scrollbackBytes = debugString(session["scrollback_bytes"]) ?? "0"
            let attachments = session["attachments"] as? [[String: Any]] ?? []
            let workspacePrefix = allWorkspaces
                ? "\(workspaceLabel)\(workspaceTitle.isEmpty ? "" : " \(workspaceTitle)") "
                : ""
            print("\(workspacePrefix)\(sessionID) attachments=\(attachments.count) size=\(effectiveCols)x\(effectiveRows) scrollback_bytes=\(scrollbackBytes)")
        }
        if !errors.isEmpty {
            throw CLIError(message: sshSessionListFailureMessage(errors))
        }
    }

    func sshSessionListFailureMessage(_ errors: [[String: Any]]) -> String {
        let count = errors.count
        let summary = "ssh-session-list failed for \(count) remote workspace\(count == 1 ? "" : "s")"
        let details = errors.map { error in
            let workspace = debugString(error["workspace_ref"])
                ?? debugString(error["workspace_id"])
                ?? "workspace:?"
            let message = userFacingRemotePTYErrorMessage(error["error"])
            return "- \(workspace): \(message)"
        }
        return ([summary] + details).joined(separator: "\n")
    }

    func runSSHSessionCleanup(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (sessionIDOpt, rem1) = parseOption(rem0, name: "--session-id")
        let closeAll = rem1.contains("--all")
        let allWorkspaces = rem1.contains("--all-workspaces")
        let remaining = rem1.filter { $0 != "--all" && $0 != "--all-workspaces" }
        if let unknown = remaining.first(where: { Self.isFlagToken($0) }) {
            throw CLIError(message: "ssh-session-cleanup: unknown flag '\(unknown)'. Known flags: --workspace <workspace>, --session-id <id>, --all, --all-workspaces")
        }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux ssh-session-cleanup [--workspace <workspace> | --all-workspaces] (--session-id <id> | --all)")
        }
        if closeAll == (sessionIDOpt != nil) {
            throw CLIError(message: "ssh-session-cleanup requires exactly one of --session-id <id> or --all")
        }
        if allWorkspaces, workspaceOpt != nil {
            throw CLIError(message: "ssh-session-cleanup: --all-workspaces cannot be combined with --workspace")
        }

        let baseParams = try sshSessionTargetParams(
            commandName: "ssh-session-cleanup",
            workspaceOpt: workspaceOpt,
            allWorkspaces: allWorkspaces,
            client: client
        )

        var closed: [String] = []
        var closedSet = Set<String>()
        let recordClosedSession: (String, String?) -> Void = { sessionID, workspaceID in
            let workspaceKey = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let dedupeKey = "\(workspaceKey.count):\(workspaceKey)\u{0}\(sessionID)"
            if closedSet.insert(dedupeKey).inserted {
                closed.append(sessionID)
            }
        }
        var errors: [[String: Any]] = []
        if closeAll {
            let listResponse = try client.sendV2(method: "workspace.remote.pty_sessions", params: baseParams)
            errors.append(contentsOf: sshSessionCleanupListErrors(listResponse["errors"] as? [[String: Any]] ?? []))
            let sessions = listResponse["sessions"] as? [[String: Any]] ?? []
            for session in sessions {
                guard let sessionID = trimmedDebugString(session["session_id"]) else {
                    errors.append(sshSessionCleanupMissingSessionIDError(session: session))
                    continue
                }
                guard let workspaceID = trimmedDebugString(session["workspace_id"])
                    ?? trimmedDebugString(baseParams["workspace_id"]) else {
                    errors.append(sshSessionCleanupMissingWorkspaceError(sessionID: sessionID, session: session))
                    continue
                }
                let params: [String: Any] = [
                    "workspace_id": workspaceID,
                    "session_id": sessionID,
                ]
                do {
                    _ = try client.sendV2(method: "workspace.remote.pty_close", params: params)
                    recordClosedSession(sessionID, workspaceID)
                } catch {
                    errors.append([
                        "session_id": sessionID,
                        "workspace_id": params["workspace_id"] ?? NSNull(),
                        "error": self.userFacingRemotePTYErrorMessage(error),
                    ])
                }
            }
        } else if let sessionID = sessionIDOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionID.isEmpty {
            if allWorkspaces {
                let listResponse = try client.sendV2(method: "workspace.remote.pty_sessions", params: baseParams)
                errors.append(contentsOf: sshSessionCleanupListErrors(
                    listResponse["errors"] as? [[String: Any]] ?? [],
                    sessionID: sessionID
                ))
                let sessions = (listResponse["sessions"] as? [[String: Any]] ?? []).filter {
                    trimmedDebugString($0["session_id"]) == sessionID
                }
                if sessions.isEmpty {
                    errors.append([
                        "session_id": sessionID,
                        "workspace_id": NSNull(),
                        "error": "persistent SSH PTY session is no longer running",
                    ])
                }
                for session in sessions {
                    guard let workspaceID = trimmedDebugString(session["workspace_id"]) else {
                        errors.append(sshSessionCleanupMissingWorkspaceError(sessionID: sessionID, session: session))
                        continue
                    }
                    do {
                        _ = try client.sendV2(method: "workspace.remote.pty_close", params: [
                            "workspace_id": workspaceID,
                            "session_id": sessionID,
                        ])
                        recordClosedSession(sessionID, workspaceID)
                    } catch {
                        errors.append([
                            "session_id": sessionID,
                            "workspace_id": workspaceID,
                            "error": self.userFacingRemotePTYErrorMessage(error),
                        ])
                    }
                }
            } else {
                var params = baseParams
                params["session_id"] = sessionID
                _ = try client.sendV2(method: "workspace.remote.pty_close", params: params)
                recordClosedSession(sessionID, trimmedDebugString(params["workspace_id"]))
            }
        } else {
            throw CLIError(message: "ssh-session-cleanup: --session-id requires a value")
        }

        let payload: [String: Any] = [
            "closed": closed,
            "count": closed.count,
            "errors": errors,
        ]
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            if !errors.isEmpty {
                throw CLIError(message: sshSessionCleanupFailureMessage(errors))
            }
        } else if !errors.isEmpty {
            if !closed.isEmpty {
                print("Closed \(closed.count) persisted SSH PTY session\(closed.count == 1 ? "" : "s")")
            }
            throw CLIError(message: sshSessionCleanupFailureMessage(errors))
        } else if closed.isEmpty {
            print("No persisted SSH PTY sessions closed")
        } else {
            print("Closed \(closed.count) persisted SSH PTY session\(closed.count == 1 ? "" : "s")")
        }
    }

    private func sshSessionCleanupMissingWorkspaceError(sessionID: String, session: [String: Any]) -> [String: Any] {
        var error: [String: Any] = [
            "session_id": sessionID,
            "workspace_id": NSNull(),
            "error": "missing workspace_id in SSH PTY session list response",
        ]
        if let workspaceRef = trimmedDebugString(session["workspace_ref"]) {
            error["workspace_ref"] = workspaceRef
        }
        return error
    }

    private func sshSessionCleanupMissingSessionIDError(session: [String: Any]) -> [String: Any] {
        var error: [String: Any] = [
            "session_id": "unknown",
            "workspace_id": trimmedDebugString(session["workspace_id"]) ?? NSNull(),
            "error": "missing session_id in SSH PTY session list response",
        ]
        if let workspaceRef = trimmedDebugString(session["workspace_ref"]) {
            error["workspace_ref"] = workspaceRef
        }
        return error
    }

    private func sshSessionCleanupListErrors(_ listErrors: [[String: Any]], sessionID: String? = nil) -> [[String: Any]] {
        listErrors.map { error in
            let workspaceValue: Any
            if let workspace = debugString(error["workspace_ref"]) ?? debugString(error["workspace_id"]) {
                workspaceValue = workspace
            } else {
                workspaceValue = NSNull()
            }
            let payload: [String: Any] = [
                "session_id": sessionID ?? debugString(error["session_id"]) ?? "workspace-query",
                "workspace_id": workspaceValue,
                "error": userFacingRemotePTYErrorMessage(error["error"]),
            ]
            return payload
        }
    }

    private func sshSessionCleanupFailureMessage(_ errors: [[String: Any]]) -> String {
        let count = errors.count
        let summary = "ssh-session-cleanup failed for \(count) persisted SSH PTY session\(count == 1 ? "" : "s")"
        let details = errors.map { error in
            let sessionID = debugString(error["session_id"]) ?? "unknown"
            let workspaceID = (debugString(error["workspace_ref"]) ?? debugString(error["workspace_id"]))
                .map { " workspace=\($0)" } ?? ""
            let message = userFacingRemotePTYErrorMessage(error["error"])
            return "- \(sessionID)\(workspaceID): \(message)"
        }
        return ([summary] + details).joined(separator: "\n")
    }

    func runSSHSessionAttach(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (sessionIDOpt, rem1) = parseOption(rem0, name: "--session-id")
        let (paneOpt, rem2) = parseOption(rem1, name: "--pane")
        let (surfaceOpt, rem3) = parseOption(rem2, name: "--surface")
        let (splitOpt, rem4) = parseOption(rem3, name: "--split")
        let (focusOpt, remaining) = parseOption(rem4, name: "--focus")
        if let unknown = remaining.first(where: { Self.isFlagToken($0) }) {
            throw CLIError(message: "ssh-session-attach: unknown flag '\(unknown)'. Known flags: --workspace <workspace>, --session-id <id>, --pane <pane>, --surface <surface>, --split <direction>, --focus <true|false>")
        }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux ssh-session-attach --session-id <id> [--workspace <workspace>] [--pane <pane> | --split <left|right|up|down> [--surface <surface>]]")
        }
        guard let sessionID = sessionIDOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            throw CLIError(message: "ssh-session-attach requires --session-id <id>")
        }
        if paneOpt != nil, splitOpt != nil {
            throw CLIError(message: "ssh-session-attach: --pane cannot be combined with --split")
        }

        let workspaceRaw = workspaceOpt ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let workspaceID = try normalizeWorkspaceHandle(workspaceRaw, client: client)
        let initialCommand = sshSessionAttachStartupCommand(sessionID: sessionID)
        var params: [String: Any] = [
            "initial_command": initialCommand,
            "remote_pty_session_id": sessionID,
        ]
        if let workspaceID {
            params["workspace_id"] = workspaceID
        }
        try applyFocusOption(focusOpt, defaultValue: true, to: &params)

        let payload: [String: Any]
        if let split = splitOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !split.isEmpty {
            params["direction"] = split
            let surfaceID = try normalizeSurfaceHandle(
                surfaceOpt ?? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"],
                client: client,
                workspaceHandle: workspaceID
            )
            if let surfaceID {
                params["surface_id"] = surfaceID
            }
            payload = try client.sendV2(method: "surface.split", params: params)
        } else {
            let paneID = try normalizePaneHandle(paneOpt, client: client, workspaceHandle: workspaceID)
            if let paneID {
                params["pane_id"] = paneID
            }
            payload = try client.sendV2(method: "surface.create", params: params)
        }

        var output = payload
        output["session_id"] = sessionID
        printV2Payload(
            output,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: v2OKSummary(output, idFormat: idFormat, kinds: ["surface", "pane", "workspace"])
        )
    }

    private func sshSessionAttachStartupCommand(sessionID: String) -> String {
        let quotedSessionID = shellQuote(sessionID)
        let currentExecutable = shellQuote(resolvedExecutableURL()?.path ?? (args.first ?? "cmux"))
        let attachCommand = "\"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" ssh-pty-attach --wait --require-existing --workspace \"$CMUX_WORKSPACE_ID\" --session-id \(quotedSessionID) --attachment-id \"${CMUX_SURFACE_ID:-}\""
        let script = ([
            "cmux_ssh_attach_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_ssh_attach_cli\" ] || [ ! -x \"$cmux_ssh_attach_cli\" ]; then cmux_ssh_attach_cli=\(currentExecutable); fi",
            "if [ -z \"$cmux_ssh_attach_cli\" ] || [ ! -x \"$cmux_ssh_attach_cli\" ]; then cmux_ssh_attach_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "if [ -z \"$cmux_ssh_attach_cli\" ]; then printf '%s\\n' '[cmux] bundled CLI not found for SSH PTY attach.' >&2; exit 127; fi",
            "if [ -z \"${CMUX_SOCKET_PATH:-}\" ]; then printf '%s\\n' '[cmux] required configuration missing for SSH PTY attach.' >&2; exit 1; fi",
            "if [ -z \"${CMUX_WORKSPACE_ID:-}\" ]; then printf '%s\\n' '[cmux] required workspace context missing for SSH PTY attach.' >&2; exit 1; fi",
        ] + sshPTYAttachRetryLoopLines(command: attachCommand)).joined(separator: "\n")
        return "/bin/sh -c \(shellQuote(script))"
    }

    private func sshPTYAttachRetryLoopLines(command: String) -> [String] {
        [
            "cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-20}\"",
            "case \"$cmux_ssh_attach_reconnect_limit\" in ''|*[!0-9]*) cmux_ssh_attach_reconnect_limit=20 ;; esac",
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*) cmux_ssh_attach_reconnect_delay=2 ;; esac",
            "cmux_ssh_attach_retry=0",
            "while :; do",
            "  \(command)",
            "  cmux_ssh_attach_status=$?",
            "  case \"$cmux_ssh_attach_status\" in 254|255) ;; *) exit \"$cmux_ssh_attach_status\" ;; esac",
            "  if [ \"$cmux_ssh_attach_retry\" -ge \"$cmux_ssh_attach_reconnect_limit\" ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_retry=$((cmux_ssh_attach_retry + 1))",
            "  if [ -t 2 ]; then printf '\\n\\033[33m[cmux] remote PTY bridge closed; reattaching (attempt %s/%s).\\033[0m\\n' \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_limit\" >&2 || true; fi",
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -gt 0 ]; then sleep \"$cmux_ssh_attach_reconnect_delay\"; fi",
            "done",
        ]
    }

    private func sshSessionTargetParams(
        commandName: String,
        workspaceOpt: String?,
        allWorkspaces: Bool,
        client: SocketClient
    ) throws -> [String: Any] {
        if allWorkspaces {
            return ["all_workspaces": true]
        }
        let workspaceRaw = workspaceOpt ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        guard let workspaceRaw,
              !workspaceRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        guard let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
            throw CLIError(message: "\(commandName): workspace not found")
        }
        return ["workspace_id": workspaceId]
    }

}
