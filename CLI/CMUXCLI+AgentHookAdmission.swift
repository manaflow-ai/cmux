import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    static let agentHookAdmissionResponseTimeoutSeconds = 0.5
    static let agentHookBarrierResponseTimeoutSeconds = 20
    // Relay authentication has three bounded response phases. Their combined
    // 1.5-second ceiling leaves 3.5 seconds for process startup, writes, and the
    // fail-open shell response before the agent terminates the hook.
    static let agentHookDeclaredTimeoutSeconds = 5
    static let agentHookDeclaredTimeoutMilliseconds = agentHookDeclaredTimeoutSeconds * 1_000
    static let maximumRelayAgentHookPayloadBytes = 4 * 1_024
    static let maximumRelayAgentHookEncodedPayloadBytes = 8 * 1_024
    static let relayClaudeForkSessionPayloadKey = "_cmux_claude_fork_session"
    static let relayClaudeForkParentSessionIDPayloadKey = "_cmux_claude_fork_parent_session_id"
    private static let maximumAgentHookInputBytes = 1 * 1_024 * 1_024
    private static let relayFilesystemIdentityKeys: Set<String> = [
        "cwd",
        "working_directory",
        "workingDirectory",
        "project_dir",
        "projectDir",
        "project_path",
        "projectPath",
        "workspacePaths",
        "workspace_paths",
        "transcript_path",
        "transcriptPath",
    ]

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

    /// Captures the identity shared by queued lifecycle events and direct
    /// decision barriers. Relay callers carry their portable TTY separately so
    /// the app can resolve routing in the admission RPC itself.
    func agentHookOrderingEnvironment(
        agent: String,
        client: SocketClient,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: processEnvironment,
            kind: agent
        )
        for key in Self.queuedAgentHookDataEnvironmentKeys(agent: agent) {
            if let value = processEnvironment[key] {
                environment[key] = value
            }
        }
        let pidEnvironmentKey = Self.agentHookPIDEnvironmentVariable(agentName: agent)
        if environment[pidEnvironmentKey].flatMap(Int.init).map({ $0 > 0 }) != true,
           let inferredPID = inferredAgentPID() {
            environment[pidEnvironmentKey] = String(inferredPID)
        }
        guard client.isRelayBacked else { return environment }

        let relayEnvironmentKeys: Set<String> = [
            "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
            "CMUX_AGENT_MANAGED_SUBAGENT",
            "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
            "CMUX_SURFACE_ID",
            "CMUX_WORKSPACE_ID",
            pidEnvironmentKey,
        ]
        return environment.filter { key, value in
            guard relayEnvironmentKeys.contains(key), !value.contains("\0") else {
                return false
            }
            let maximumBytes = key == "CMUX_SURFACE_ID" || key == "CMUX_WORKSPACE_ID"
                ? 256
                : 32
            return value.utf8.count <= maximumBytes
        }
    }

    /// Establishes the direct hook behind every earlier queued event in the
    /// same socket/surface lane. The app performs the bounded wait; this CLI
    /// retains its stdin and synchronous decision stdout/exit contract.
    func waitForPriorAgentHookDeliveries(
        agent: String,
        client: SocketClient
    ) throws {
        let environment = agentHookOrderingEnvironment(agent: agent, client: client)
        var params: [String: Any] = [
            "agent": agent,
            "environment": environment,
            "relay_backed": client.isRelayBacked,
        ]
        if client.isRelayBacked, let callerTTY = resolveCallerTTYName() {
            params["caller_tty"] = callerTTY
        }
        _ = try client.sendV2(
            method: "agent.hook.barrier",
            params: params,
            responseTimeout: TimeInterval(Self.agentHookBarrierResponseTimeoutSeconds)
        )
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
        let environment = agentHookOrderingEnvironment(
            agent: agent,
            client: client,
            processEnvironment: processEnvironment
        )
        let rawPayload = Self.readBoundedAgentHookInput() ?? "{}"
        let admittedPayload = client.isRelayBacked
            ? relayEnrichedAgentHookPayload(
                rawPayload,
                agent: agent,
                subcommand: subcommand,
                processEnvironment: processEnvironment
            )
            : rawPayload
        let payload = compactAgentHookPayload(
            admittedPayload,
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
        } else if let callerTTY = resolveCallerTTYName() {
            params["caller_tty"] = callerTTY
        }
        _ = try client.sendV2(
            method: "agent.hook.enqueue",
            params: params,
            responseTimeout: TimeInterval(Self.agentHookAdmissionResponseTimeoutSeconds)
        )
        print("{}")
    }

    /// Converts remote filesystem/process evidence into bounded, portable
    /// payload fields before the relay admits the event. Local replay must not
    /// inspect paths or PIDs that belong to the remote host.
    private func relayEnrichedAgentHookPayload(
        _ rawPayload: String,
        agent: String,
        subcommand: String,
        processEnvironment: [String: String]
    ) -> String {
        let parsed = parseClaudeHookInput(rawInput: rawPayload)
        guard var object = parsed.rawObject else { return rawPayload }
        var changed = false

        if agent == "claude" {
            if object.removeValue(forKey: Self.relayClaudeForkSessionPayloadKey) != nil {
                changed = true
            }
            if object.removeValue(
                forKey: Self.relayClaudeForkParentSessionIDPayloadKey
            ) != nil {
                changed = true
            }
            if let forkParentSessionID = relayClaudeForkParentSessionID(
                processEnvironment: processEnvironment
            ) {
                object[Self.relayClaudeForkSessionPayloadKey] = true
                object[Self.relayClaudeForkParentSessionIDPayloadKey] =
                    compactQueuedAgentHookString(
                        forkParentSessionID,
                        maximumLength: 256
                    )
                changed = true
            }
        }

        if agent == "codex",
           subcommand == "stop",
           codexHookFailureCandidate(from: parsed.object) == nil,
           !codexHookStopPayloadHasAssistantMessage(parsed.object),
           let transcriptPath = parsed.transcriptPath {
            switch readCodexTranscriptFailure(
                path: transcriptPath,
                turnId: parsed.turnId,
                requireTerminalCompletion: false
            ) {
            case .failure(let failure):
                object["type"] = failure.isStreamError ? "stream_error" : "error"
                object["message"] = compactQueuedAgentHookString(
                    failure.message,
                    maximumLength: 240
                )
                if let codexErrorInfo = failure.codexErrorInfo {
                    object["codex_error_info"] = compactQueuedAgentHookString(
                        codexErrorInfo,
                        maximumLength: 240
                    )
                }
                if let additionalDetails = failure.additionalDetails {
                    object["additional_details"] = compactQueuedAgentHookString(
                        additionalDetails,
                        maximumLength: 240
                    )
                }
                changed = true
            case .unavailable, .pending, .healthy:
                break
            }
        }

        if agent == "rovodev",
           parsed.sessionId == nil,
           let sessionID = RovoDevSessionResolver.inferredRovoDevSessionId(
               cwd: parsed.cwd ?? processEnvironment["PWD"],
               env: processEnvironment
            ) {
            object["session_id"] = compactQueuedAgentHookString(
                sessionID,
                maximumLength: 256
            )
            changed = true
        }

        let portable = removingRelayFilesystemIdentity(from: object)
        object = portable.value as? [String: Any] ?? [:]
        changed = changed || portable.changed

        guard changed,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let payload = String(data: data, encoding: .utf8) else {
            return rawPayload
        }
        return payload
    }

    private func removingRelayFilesystemIdentity(
        from value: Any
    ) -> (value: Any, changed: Bool) {
        if let object = value as? [String: Any] {
            var portable: [String: Any] = [:]
            var changed = false
            for (key, nestedValue) in object {
                if Self.relayFilesystemIdentityKeys.contains(key) {
                    changed = true
                    continue
                }
                let nested = removingRelayFilesystemIdentity(from: nestedValue)
                portable[key] = nested.value
                changed = changed || nested.changed
            }
            return (portable, changed)
        }
        if let array = value as? [Any] {
            var changed = false
            let portable = array.map { nestedValue in
                let nested = removingRelayFilesystemIdentity(from: nestedValue)
                changed = changed || nested.changed
                return nested.value
            }
            return (portable, changed)
        }
        return (value, false)
    }

    /// Extracts only portable fork intent from trusted launcher capture. Remote
    /// executable paths and the rest of argv never cross the relay boundary.
    private func relayClaudeForkParentSessionID(
        processEnvironment: [String: String]
    ) -> String? {
        guard normalizedHookValue(
            processEnvironment["CMUX_AGENT_LAUNCH_KIND"]
        )?.lowercased() == "claude",
        let encodedArguments = normalizedHookValue(
            processEnvironment["CMUX_AGENT_LAUNCH_ARGV_B64"]
        ),
        let data = Data(base64Encoded: encodedArguments) else {
            return nil
        }
        let arguments = data.split(
            separator: 0,
            omittingEmptySubsequences: false
        ).compactMap { String(data: $0, encoding: .utf8) }
        guard arguments.count > 1,
              arguments.contains(where: { argument in
                  if argument == "--fork-session" { return true }
                  guard argument.hasPrefix("--fork-session=") else { return false }
                  let value = argument
                      .dropFirst("--fork-session=".count)
                      .lowercased()
                  return !["false", "0", "no", "off"].contains(value)
              }) else {
            return nil
        }
        for (index, argument) in arguments.enumerated() {
            if argument == "--resume" || argument == "-r" {
                guard index + 1 < arguments.count else { return nil }
                return normalizedHookValue(arguments[index + 1])
            }
            if argument.hasPrefix("--resume=") {
                return normalizedHookValue(
                    String(argument.dropFirst("--resume=".count))
                )
            }
        }
        return nil
    }

    /// Reads only a finite admission envelope before any string materialization
    /// or JSON parsing. Hooks above 1 MiB fail open with a neutral payload: the
    /// lifecycle event is still admitted, but oversized untrusted detail is
    /// discarded instead of making the foreground hook process scale with stdin.
    private static func readBoundedAgentHookInput(
        handle: FileHandle = .standardInput
    ) -> String? {
        var data = Data()
        while data.count <= maximumAgentHookInputBytes {
            let remainingBytes = maximumAgentHookInputBytes + 1 - data.count
            let chunkSize = min(64 * 1_024, remainingBytes)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else {
                return String(data: data, encoding: .utf8)
            }
            data.append(chunk)
        }
        return nil
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
        for key in [
            "fullyIdle",
            "cmux_notification_routed",
            Self.relayClaudeForkSessionPayloadKey,
        ] {
            if let value = rawObject[key] as? Bool {
                fallback[key] = value
            }
        }
        if let forkParentSessionID = rawObject[
            Self.relayClaudeForkParentSessionIDPayloadKey
        ] as? String {
            fallback[Self.relayClaudeForkParentSessionIDPayloadKey] =
                compactQueuedAgentHookString(
                    forkParentSessionID,
                    maximumLength: 256
                )
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
