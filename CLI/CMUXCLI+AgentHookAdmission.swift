import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    static let agentHookAdmissionResponseTimeoutSeconds = 1
    static let agentHookDeclaredTimeoutSeconds = 3
    static let agentHookDeclaredTimeoutMilliseconds = agentHookDeclaredTimeoutSeconds * 1_000
    static let maximumRelayAgentHookPayloadBytes = 4 * 1_024
    static let maximumRelayAgentHookEncodedPayloadBytes = 8 * 1_024

    /// Builds a fail-open command that admits a non-decision hook to the app's
    /// ordered delivery queue. The hook process performs no downstream delivery.
    static func queuedAgentHookShellCommand(
        agent: String,
        subcommand: String,
        disableEnvironmentVariable: String
    ) -> String {
        let pidEnvironmentVariable = agentHookPIDEnvironmentVariable(agentName: agent)
        let executableExpression: String
        switch agent {
        case "claude":
            executableExpression = "${CMUX_CLAUDE_HOOK_CMUX_BIN:-${CMUX_BUNDLED_CLI_PATH:-}}"
        case "codex":
            executableExpression = "${CMUX_CODEX_HOOK_CMUX_BIN:-${CMUX_BUNDLED_CLI_PATH:-}}"
        default:
            executableExpression = "${CMUX_BUNDLED_CLI_PATH:-}"
        }
        return [
            "cmux_cli=\"\(executableExpression)\"",
            "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "agent_pid=\"${\(pidEnvironmentVariable):-${PPID:-}}\"",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(disableEnvironmentVariable)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \(pidEnvironmentVariable)=\"$agent_pid\" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(agentHookAdmissionResponseTimeoutSeconds) \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" hooks enqueue \(agent) \(subcommand) 2>/dev/null || echo '{}'; else \(pidEnvironmentVariable)=\"$agent_pid\" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(agentHookAdmissionResponseTimeoutSeconds) \"$cmux_cli\" hooks enqueue \(agent) \(subcommand) 2>/dev/null || echo '{}'; fi; else echo '{}'; fi",
        ].joined(separator: "; ")
    }

    /// Sends one immutable hook event to the app-owned queue, then returns the
    /// agent's neutral response. Downstream CLI/socket work happens in the app.
    func enqueueAgentHook(commandArgs: [String], client: SocketClient) throws {
        guard commandArgs.count == 2 else {
            throw CLIError(message: "Usage: cmux hooks enqueue <agent> <subcommand>")
        }
        let agent = commandArgs[0].lowercased()
        let subcommand = commandArgs[1].lowercased()
        let deliveryPolicy = AgentHookDeliveryPolicy()
        guard deliveryPolicy.supportsQueuedDelivery(agent: agent, subcommand: subcommand) else {
            throw CLIError(message: "Unsupported queued hook: \(agent) \(subcommand)")
        }

        let processEnvironment = ProcessInfo.processInfo.environment
        var environment = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: processEnvironment,
            kind: agent
        )
        for key in Self.queuedAgentHookDataEnvironmentKeys(agent: agent) {
            if let value = processEnvironment[key] {
                environment[key] = value
            }
        }
        if client.isRelayBacked {
            let relayEnvironmentKeys: Set<String> = [
                "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
                "CMUX_AGENT_MANAGED_SUBAGENT",
                "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
                "CMUX_SURFACE_ID",
                "CMUX_WORKSPACE_ID",
                Self.agentHookPIDEnvironmentVariable(agentName: agent),
            ]
            environment = environment.filter { key, value in
                guard relayEnvironmentKeys.contains(key), !value.contains("\0") else {
                    return false
                }
                let maximumBytes = key == "CMUX_SURFACE_ID" || key == "CMUX_WORKSPACE_ID"
                    ? 256
                    : 32
                return value.utf8.count <= maximumBytes
            }
        }
        let rawPayload = String(
            data: FileHandle.standardInput.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let payload = compactAgentHookPayload(
            rawPayload,
            maximumBytes: client.isRelayBacked
                ? Self.maximumRelayAgentHookPayloadBytes
                : AgentHookDeliveryPolicy.maximumPayloadBytes,
            maximumEncodedBytes: client.isRelayBacked
                ? Self.maximumRelayAgentHookEncodedPayloadBytes
                : nil
        )
        var params: [String: Any] = [
            "agent": agent,
            "subcommand": subcommand,
            "payload": payload,
            "relay_backed": client.isRelayBacked,
            "environment": environment,
        ]
        if !client.isRelayBacked {
            params["socket_path"] = client.socketPath
        }
        _ = try client.sendV2(
            method: "agent.hook.enqueue",
            params: params,
            responseTimeout: TimeInterval(Self.agentHookAdmissionResponseTimeoutSeconds)
        )
        print("{}")
    }

    private func compactAgentHookPayload(
        _ rawPayload: String,
        maximumBytes: Int,
        maximumEncodedBytes: Int?
    ) -> String {
        let compactor = AgentHookPayloadCompactor()
        guard !compactor.payloadFits(
            rawPayload,
            maximumPayloadBytes: maximumBytes,
            maximumEncodedPayloadBytes: maximumEncodedBytes
        ) else {
            return rawPayload
        }
        let parsed = parseClaudeHookInput(rawInput: rawPayload)
        var compact = parsed.object ?? [:]
        if let sessionID = parsed.sessionId {
            compact["session_id"] = sessionID
        }
        if let turnID = parsed.turnId {
            compact["turn_id"] = turnID
        }
        if let cwd = parsed.cwd {
            compact["cwd"] = cwd
        }
        if let transcriptPath = parsed.transcriptPath {
            compact["transcript_path"] = transcriptPath
        }
        var candidates: [String] = []
        if JSONSerialization.isValidJSONObject(compact),
           let compactData = try? JSONSerialization.data(
               withJSONObject: compact,
               options: [.sortedKeys, .withoutEscapingSlashes]
           ),
           let compactPayload = String(data: compactData, encoding: .utf8) {
            candidates.append(compactPayload)
        }

        var identity: [String: String] = [:]
        identity["session_id"] = parsed.sessionId
        identity["turn_id"] = parsed.turnId
        identity["cwd"] = parsed.cwd.map { String($0.prefix(512)) }
        identity["transcript_path"] = parsed.transcriptPath.map { String($0.prefix(512)) }
        if let identityData = try? JSONSerialization.data(
            withJSONObject: identity,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
        let identityPayload = String(data: identityData, encoding: .utf8) {
            candidates.append(identityPayload)
        }
        return compactor.firstFittingPayload(
            in: candidates,
            maximumPayloadBytes: maximumBytes,
            maximumEncodedPayloadBytes: maximumEncodedBytes
        )
    }

    private static func queuedAgentHookDataEnvironmentKeys(agent: String) -> [String] {
        [
            "PWD",
            "CMUX_AGENT_HOOK_STATE_DIR", "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
            "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD",
            "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_MANAGED_SUBAGENT", "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
            "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID",
            agentHookPIDEnvironmentVariable(agentName: agent),
        ]
    }

    static func agentHookPIDEnvironmentVariable(agentName: String) -> String {
        AgentHookDeliveryPolicy().pidEnvironmentVariable(agentName: agentName)
    }

    static func agentHookCanRunQueued(agent: String, subcommand: String) -> Bool {
        AgentHookDeliveryPolicy().supportsQueuedDelivery(agent: agent, subcommand: subcommand)
    }
}
