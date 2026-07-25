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
        let executableExpression = agentHookCLIExecutableExpression(agent: agent)
        return [
            "cmux_cli=\"\(executableExpression)\"",
            "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "agent_pid=\"${\(pidEnvironmentVariable):-${PPID:-}}\"",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(disableEnvironmentVariable)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \(pidEnvironmentVariable)=\"$agent_pid\" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(agentHookAdmissionResponseTimeoutSeconds) \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" hooks enqueue \(agent) \(subcommand) 2>/dev/null || echo '{}'; else \(pidEnvironmentVariable)=\"$agent_pid\" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(agentHookAdmissionResponseTimeoutSeconds) \"$cmux_cli\" hooks enqueue \(agent) \(subcommand) 2>/dev/null || echo '{}'; fi; else echo '{}'; fi",
        ].joined(separator: "; ")
    }

    static func agentHookCLIExecutableExpression(agent: String) -> String {
        switch agent {
        case "claude":
            return "${CMUX_CLAUDE_HOOK_CMUX_BIN:-${CMUX_BUNDLED_CLI_PATH:-}}"
        case "codex":
            return "${CMUX_CODEX_HOOK_CMUX_BIN:-${CMUX_BUNDLED_CLI_PATH:-}}"
        default:
            return "${CMUX_BUNDLED_CLI_PATH:-}"
        }
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

        let behavioralFallback = compactAgentHookBehavioralFallback(parsed)
        if let identityData = try? JSONSerialization.data(
            withJSONObject: behavioralFallback,
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

    /// Preserves the fields that determine lifecycle behavior even when a rich
    /// payload is too large for relay transport. Values are bounded so this
    /// candidate remains below both the raw and JSON-encoded relay limits.
    private func compactAgentHookBehavioralFallback(
        _ parsed: ClaudeHookParsedInput
    ) -> [String: Any] {
        var fallback: [String: Any] = [:]
        fallback["session_id"] = parsed.sessionId.map {
            compactQueuedAgentHookString($0, maximumLength: 256)
        }
        fallback["turn_id"] = parsed.turnId.map {
            compactQueuedAgentHookString($0, maximumLength: 256)
        }
        fallback["cwd"] = parsed.cwd.map {
            compactQueuedAgentHookString($0, maximumLength: 512)
        }
        fallback["transcript_path"] = parsed.transcriptPath.map {
            compactQueuedAgentHookString($0, maximumLength: 512)
        }

        guard let rawObject = parsed.rawObject else { return fallback }
        let toolName = firstString(in: rawObject, keys: ["tool_name", "toolName"])
        fallback["tool_name"] = toolName.map {
            compactQueuedAgentHookString($0, maximumLength: 80)
        }
        fallback["hook_event_name"] = firstString(
            in: rawObject,
            keys: ["hook_event_name", "hookEventName", "event_name", "event"]
        ).map {
            compactQueuedAgentHookString($0, maximumLength: 80)
        }
        fallback["permission_mode"] = firstString(
            in: rawObject,
            keys: ["permission_mode", "permissionMode"]
        ).map {
            compactQueuedAgentHookString($0, maximumLength: 80)
        }
        if let toolName,
           let compactToolInput = parsed.object?["tool_input"] as? [String: Any],
           let toolSummary = compactQueuedAgentHookToolSummary(
               toolName: toolName,
               toolInput: compactToolInput
           ) {
            fallback["tool_input"] = toolSummary
        }
        return fallback
    }

    private func compactQueuedAgentHookToolSummary(
        toolName: String,
        toolInput: [String: Any]
    ) -> [String: Any]? {
        if toolName == "AskUserQuestion",
           let firstQuestion = (toolInput["questions"] as? [[String: Any]])?.first {
            var question: [String: Any] = [:]
            for key in ["question", "header"] {
                if let value = firstQuestion[key] as? String {
                    question[key] = compactQueuedAgentHookString(
                        value,
                        maximumLength: key == "question" ? 180 : 80
                    )
                }
            }
            if let options = firstQuestion["options"] as? [[String: Any]] {
                question["options"] = options.prefix(4).compactMap { option -> [String: String]? in
                    guard let label = option["label"] as? String else { return nil }
                    return [
                        "label": compactQueuedAgentHookString(label, maximumLength: 60),
                    ]
                }
            }
            return question.isEmpty ? nil : ["questions": [question]]
        }

        if toolName == "ExitPlanMode", let plan = toolInput["plan"] as? String {
            return [
                "plan": compactQueuedAgentHookString(plan, maximumLength: 512),
            ]
        }

        for key in ["file_path", "command", "pattern", "description", "query", "planFilePath"] {
            if let value = toolInput[key] as? String {
                return [
                    key: compactQueuedAgentHookString(value, maximumLength: 240),
                ]
            }
        }
        return nil
    }

    private func compactQueuedAgentHookString(
        _ value: String,
        maximumLength: Int
    ) -> String {
        truncate(normalizedSingleLine(value), maxLength: maximumLength)
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
