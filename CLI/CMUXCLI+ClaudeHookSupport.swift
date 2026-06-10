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


// MARK: - Agent status, lifecycle, terminal binding
extension CMUXCLI {
    static let claudeCodeStatusKey = "claude_code"

    private static var allowedAgentLifecycleStatusKeys: Set<String> {
        var keys = Set(agentDefs.map(\.statusKey))
        keys.formUnion(AgentHibernationLifecycleStatusKeys.allowedStatusKeys)
        keys.insert(claudeCodeStatusKey)
        return keys
    }

    func claudeCronCreateGuardResponse(_ object: [String: Any]?) -> String {
        guard let object,
              object["tool_name"] as? String == "CronCreate",
              let input = object["tool_input"] as? [String: Any],
              claudeCronCreateDurableRequested(input["durable"]) else {
            return "{}"
        }

        return jsonString([
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "cmux does not support durable Claude Code cron jobs. CronCreate durable:true would be silently downgraded to session-only in this environment, so cmux denied the tool call instead. Re-run with durable:false for a session-only job, or use an external scheduler or state-file resume path for persistence."
            ]
        ])
    }

    private func claudeCronCreateDurableRequested(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes":
                return true
            default:
                return false
            }
        }
        return false
    }

    func setClaudeStatus(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String? = nil,
        value: String,
        icon: String,
        color: String,
        pid: Int? = nil
    ) throws {
        var cmd = "set_status \(Self.claudeCodeStatusKey) \(value) --icon=\(icon) --color=\(color) --tab=\(workspaceId)\(socketPanelOption(surfaceId))"
        if let pid {
            cmd += " --pid=\(pid)"
        }
        _ = try client.send(command: cmd)
    }

    func setAgentLifecycle(
        client: SocketClient,
        key: String,
        lifecycle: AgentHibernationLifecycleState,
        workspaceId: String,
        surfaceId: String?
    ) {
        guard Self.allowedAgentLifecycleStatusKeys.contains(key) else {
            fputs("Warning: unsupported agent lifecycle key\n", stderr)
            return
        }
        do {
            _ = try sendV1Command(
                "set_agent_lifecycle \(key) \(lifecycle.rawValue) --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                client: client
            )
        } catch {
            fputs("Warning: failed to set agent lifecycle\n", stderr)
        }
    }

    func runAgentHibernation(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: "Usage: cmux agent-hibernation <on|off> [--json]")
        }
        let response: String
        switch subcommand {
        case "on", "enable":
            response = try sendV1Command("agent_hibernation on", client: client)
        case "off", "disable":
            response = try sendV1Command("agent_hibernation off", client: client)
        default:
            throw CLIError(message: "Usage: cmux agent-hibernation <on|off> [--json]")
        }

        if jsonOutput {
            let ok = response == "OK"
            var fallback: [String: Any] = ["ok": ok]
            if !ok {
                fallback["message"] = response
            }
            print(jsonString(fallback))
        } else {
            print(response)
        }
    }

    func shouldApplyClaudeHookVisibleMutation(
        sessionStore: ClaudeHookSessionStore,
        parsedInput: ClaudeHookParsedInput,
        workspaceId: String,
        telemetry: CLISocketSentryTelemetry
    ) -> Bool {
        shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            sessionId: parsedInput.sessionId,
            turnId: parsedInput.turnId,
            workspaceId: workspaceId,
            telemetry: telemetry
        )
    }

    func shouldApplyClaudeHookVisibleMutation(
        sessionStore: ClaudeHookSessionStore,
        sessionId: String?,
        turnId: String?,
        workspaceId: String,
        telemetry: CLISocketSentryTelemetry
    ) -> Bool {
        do {
            return try sessionStore.isCurrent(
                sessionId: sessionId,
                workspaceId: workspaceId,
                turnId: turnId
            )
        } catch {
            telemetry.breadcrumb(
                "claude-hook.is-current.error",
                data: [
                    "error": String(describing: error),
                    "session_id": sessionId ?? "",
                    "workspace_id": workspaceId,
                    "turn_id": turnId ?? "",
                ]
            )
            return true
        }
    }

    func shouldReplaceStoppedClaudeSession(
        sessionStore: ClaudeHookSessionStore,
        parsedInput: ClaudeHookParsedInput,
        workspaceId: String,
        telemetry: CLISocketSentryTelemetry
    ) -> Bool {
        do {
            return try sessionStore.canReplaceActiveSession(
                sessionId: parsedInput.sessionId,
                workspaceId: workspaceId
            )
        } catch {
            telemetry.breadcrumb(
                "claude-hook.can-replace-active.error",
                data: [
                    "error": String(describing: error),
                    "session_id": parsedInput.sessionId ?? "",
                    "workspace_id": workspaceId,
                ]
            )
            return false
        }
    }

    func isClaudeClearSessionStart(_ parsedInput: ClaudeHookParsedInput) -> Bool {
        guard let source = parsedInput.object?["source"] as? String else {
            return false
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "clear"
    }

    func socketPanelOption(_ surfaceId: String?) -> String {
        guard let surfaceId = surfaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !surfaceId.isEmpty,
              UUID(uuidString: surfaceId) != nil else {
            return ""
        }
        return " --panel=\(surfaceId)"
    }

    func resolvePreferredWorkspaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        client: SocketClient
    ) throws -> String {
        if let preferred = nonEmptyClaudeHookIdentifier(preferred) {
            return try resolveWorkspaceIdForClaudeHook(preferred, client: client)
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback) {
            return try resolveWorkspaceIdForClaudeHook(fallback, client: client)
        }
        return try resolveWorkspaceIdForClaudeHook(nil, client: client)
    }

    func resolvePreferredSurfaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let preferred = nonEmptyClaudeHookIdentifier(preferred) {
            return try resolveSurfaceIdForClaudeHook(preferred, workspaceId: workspaceId, client: client)
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback) {
            return try resolveSurfaceIdForClaudeHook(fallback, workspaceId: workspaceId, client: client)
        }
        return try resolveSurfaceIdForClaudeHook(nil, workspaceId: workspaceId, client: client)
    }

    func nonEmptyClaudeHookIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func shouldIgnoreClaudeHookTeardownError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        let benignFragments = [
            "tabmanager not available",
            "no workspace selected",
            "workspace not found",
            "workspace ref not found",
            "workspace index not found",
            "surface not found",
            "surface ref not found",
            "surface index not found",
            "unable to resolve surface id",
            "panel not found",
            "tab not found",
            "failed to write to socket",
            "socket read error",
            "not connected"
        ]
        return benignFragments.contains { message.contains($0) }
    }

    func describeAskUserQuestion(_ object: [String: Any]?) -> String? {
        guard let object,
              let input = object["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first else { return nil }

        var parts: [String] = []

        if let question = first["question"] as? String, !question.isEmpty {
            parts.append(question)
        } else if let header = first["header"] as? String, !header.isEmpty {
            parts.append(header)
        }

        if let options = first["options"] as? [[String: Any]] {
            let labels = options.compactMap { $0["label"] as? String }
            if !labels.isEmpty {
                parts.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }

        if parts.isEmpty { return "Asking a question" }
        return parts.joined(separator: "\n")
    }

    func describeToolUse(_ object: [String: Any]?) -> String? {
        guard let object, let toolName = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any]

        switch toolName {
        case "Read":
            if let path = input?["file_path"] as? String {
                return "Reading \(shortenPath(path))"
            }
            return "Reading file"
        case "Edit":
            if let path = input?["file_path"] as? String {
                return "Editing \(shortenPath(path))"
            }
            return "Editing file"
        case "Write":
            if let path = input?["file_path"] as? String {
                return "Writing \(shortenPath(path))"
            }
            return "Writing file"
        case "Bash":
            if let cmd = input?["command"] as? String {
                let first = cmd.components(separatedBy: .whitespacesAndNewlines).first ?? cmd
                let short = String(first.prefix(30))
                return "Running \(short)"
            }
            return "Running command"
        case "Glob":
            if let pattern = input?["pattern"] as? String {
                return "Searching \(String(pattern.prefix(30)))"
            }
            return "Searching files"
        case "Grep":
            if let pattern = input?["pattern"] as? String {
                return "Grep \(String(pattern.prefix(30)))"
            }
            return "Searching code"
        case "Agent":
            if let desc = input?["description"] as? String {
                return String(desc.prefix(40))
            }
            return "Subagent"
        case "WebFetch":
            return "Fetching URL"
        case "WebSearch":
            if let query = input?["query"] as? String {
                return "Search: \(String(query.prefix(30)))"
            }
            return "Web search"
        default:
            return toolName
        }
    }

    private func shortenPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return name.isEmpty ? String(path.suffix(30)) : name
    }

    private func resolveWorkspaceIdForClaudeHook(_ raw: String?, client: SocketClient) throws -> String {
        try resolveWorkspaceIdAllowingFallback(raw, client: client)
    }

    private func resolveSurfaceIdForClaudeHook(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        try resolveSurfaceIdAllowingFallback(raw, workspaceId: workspaceId, client: client)
    }

    func resolveWorkspaceIdAllowingFallback(
        _ raw: String?,
        client: SocketClient
    ) throws -> String {
        if let raw,
           !raw.isEmpty,
           let candidate = try? resolveWorkspaceId(raw, client: client),
           (try? client.sendV2(method: "surface.list", params: ["workspace_id": candidate])) != nil {
            return candidate
        }
        if let callerWorkspaceId = resolveCallerWorkspaceIdByTTY(client: client),
           (try? client.sendV2(method: "surface.list", params: ["workspace_id": callerWorkspaceId])) != nil {
            return callerWorkspaceId
        }
        return try resolveWorkspaceId(nil, client: client)
    }

    func resolveSurfaceIdAllowingFallback(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let raw,
           !raw.isEmpty,
           let candidate = try? resolveSurfaceId(raw, workspaceId: workspaceId, client: client),
           let listed = try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId]) {
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            if items.contains(where: {
                ($0["id"] as? String) == candidate || ($0["ref"] as? String) == candidate
            }) {
                return candidate
            }
        }
        if let callerSurfaceId = resolveCallerSurfaceIdByTTY(workspaceId: workspaceId, client: client),
           let listed = try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId]) {
            let items = listed["surfaces"] as? [[String: Any]] ?? []
            if items.contains(where: {
                ($0["id"] as? String) == callerSurfaceId || ($0["ref"] as? String) == callerSurfaceId
            }) {
                return callerSurfaceId
            }
        }
        return try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
    }

    struct CallerTerminalBinding {
        let workspaceId: String
        let surfaceId: String
    }

    private func resolveCallerWorkspaceIdByTTY(client: SocketClient) -> String? {
        resolveCallerTerminalBindingByTTY(client: client)?.workspaceId
    }

    private func resolveCallerSurfaceIdByTTY(workspaceId: String, client: SocketClient) -> String? {
        guard let binding = resolveCallerTerminalBindingByTTY(client: client),
              binding.workspaceId == workspaceId else {
            return nil
        }
        return binding.surfaceId
    }

    func resolveCallerTerminalBindingByTTY(client: SocketClient) -> CallerTerminalBinding? {
        guard let ttyName = resolveCallerTTYName() else {
            return nil
        }
        return resolveTerminalBinding(ttyName: ttyName, client: client)
    }

    func resolveAgentProcessTerminalBinding(pid: Int?, client: SocketClient) -> CallerTerminalBinding? {
        guard let pid else { return nil }
        guard let payload = try? client.sendV2(
            method: "system.top",
            params: ["all_windows": true, "include_processes": true],
            responseTimeout: 2.0
        ) else {
            return nil
        }
        let windows = payload["windows"] as? [[String: Any]] ?? []
        for window in windows {
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                guard let workspaceId = normalizedHandleValue(workspace["id"] as? String)
                    ?? normalizedHandleValue(workspace["ref"] as? String) else {
                    continue
                }
                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for pane in panes {
                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for surface in surfaces {
                        guard let surfaceId = normalizedHandleValue(surface["id"] as? String)
                            ?? normalizedHandleValue(surface["ref"] as? String) else {
                            continue
                        }
                        let topLevelPIDs = (surface["top_level_pids"] as? [Any] ?? [])
                            .compactMap { Self.intValue($0) }
                        if topLevelPIDs.contains(pid) {
                            return CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId)
                        }
                        let processes = surface["processes"] as? [[String: Any]] ?? []
                        if topProcessTreeContainsPID(processes, pid: pid) {
                            return CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId)
                        }
                    }
                }
            }
        }
        return nil
    }

    private func topProcessTreeContainsPID(_ processes: [[String: Any]], pid: Int) -> Bool {
        for process in processes {
            if Self.intValue(process["pid"]) == pid {
                return true
            }
            if let resources = process["resources"] as? [String: Any],
               (resources["pids"] as? [Any] ?? []).compactMap({ Self.intValue($0) }).contains(pid) {
                return true
            }
            if let children = process["children"] as? [[String: Any]],
               topProcessTreeContainsPID(children, pid: pid) {
                return true
            }
        }
        return false
    }

    private func resolveTerminalBinding(ttyName: String, client: SocketClient) -> CallerTerminalBinding? {
        guard let payload = try? client.sendV2(method: "debug.terminals") else {
            return nil
        }
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        for terminal in terminals {
            guard normalizedTTYName(terminal["tty"] as? String) == ttyName,
                  let workspaceId = normalizedHandleValue(terminal["workspace_id"] as? String),
                  let surfaceId = normalizedHandleValue(terminal["surface_id"] as? String) else {
                continue
            }
            return CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId)
        }
        return nil
    }

    func resolveCallerTTYName() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["CMUX_CLI_TTY_NAME", "CMUX_TTY_NAME", "TTY", "SSH_TTY"] {
            if let ttyName = normalizedTTYName(env[key]) {
                return ttyName
            }
        }
        for fileDescriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            if let rawTTYName = ttyname(fileDescriptor),
               let ttyName = normalizedTTYName(String(cString: rawTTYName)) {
                return ttyName
            }
        }
        return nil
    }

    private func normalizedTTYName(_ raw: String?) -> String? {
        guard let trimmed = normalizedHandleValue(raw == "not a tty" ? nil : raw) else {
            return nil
        }
        let components = trimmed.split(separator: "/")
        if let last = components.last, !last.isEmpty {
            return String(last)
        }
        return trimmed
    }

}
