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


// MARK: - Feed telemetry
extension CMUXCLI {
    // MARK: - Feed telemetry helper

    /// Best-effort `feed.push` call used by the per-agent hook handlers
    /// so session-start / prompt-submit / stop events show up in Feed's
    /// "All" view even when no permission/plan/question event fires.
    /// Failures are swallowed.
    func sendBestEffortFeedTelemetry(socketPath: String, line: String, socketPassword: String?) {
        let oneWayClient = SocketClient(path: socketPath)
        defer { oneWayClient.close() }
        do {
            try oneWayClient.connectWithoutRetry(responseTimeout: 0.05)
            try authenticateClientIfNeeded(
                oneWayClient,
                explicitPassword: socketPassword,
                socketPath: socketPath,
                responseTimeout: 0.05
            )
            try oneWayClient.sendOneWay(command: line, writeTimeout: 0.05)
        } catch {
            return
        }
    }

    func sendFeedTelemetry(
        client: SocketClient,
        source: String,
        subcommand: String,
        parsedInput: ClaudeHookParsedInput,
        workspaceId: String? = nil,
        socketPassword: String? = nil
    ) {
        let hookEventName = Self.feedEventName(forClaudeSubcommand: subcommand)
        guard !hookEventName.isEmpty else { return }
        let promptText = hookEventName == "UserPromptSubmit"
            ? (feedPromptText(from: parsedInput.object) ?? parsedInput.rawFallback)
            : nil
        let fallbackObject = parsedInput.rawObject ?? parsedInput.object ?? [:]
        let agentPid = agentPidForFeedSource(source)
        let sessionId = parsedInput.sessionId ?? stableFallbackFeedSessionId(
            source: source,
            rawObject: fallbackObject,
            agentPid: agentPid
        )
        var event: [String: Any] = [
            "session_id": "\(source)-\(sessionId)",
            "hook_event_name": hookEventName,
            "_source": source,
            "_ppid": agentPid,
        ]
        if let workspaceId = feedWorkspaceId(rawObject: parsedInput.object, fallback: workspaceId) {
            event["workspace_id"] = workspaceId
        }
        if let cwd = parsedInput.cwd { event["cwd"] = cwd }
        let toolName = parsedInput.object?["tool_name"] as? String
        if let toolName, !toolName.isEmpty {
            event["tool_name"] = toolName
        }
        if let toolInput = parsedInput.object?["tool_input"] {
            event["tool_input"] = toolInput
        }
        if let context = feedContextForEvent(
            source: source,
            hookEventName: hookEventName,
            toolName: toolName,
            toolInput: event["tool_input"],
            rawObject: parsedInput.object,
            transcriptPath: parsedInput.transcriptPath
        ) {
            event["context"] = context
        }
        enrichUserPromptSubmitFeedEvent(
            &event,
            hookEventName: hookEventName,
            promptText: promptText
        )
        event["_opencode_request_id"] = "\(source)-\(sessionId)-\(hookEventName)-\(Int(Date().timeIntervalSince1970 * 1000))"

        let frame: [String: Any] = [
            "method": "feed.push",
            "params": [
                "event": event,
                "wait_timeout_seconds": 0,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let line = String(data: data, encoding: .utf8)
        else { return }
        sendBestEffortFeedTelemetry(socketPath: client.socketPath, line: line, socketPassword: socketPassword)
    }

    func feedContextForEvent(
        source: String,
        hookEventName: String,
        toolName: String?,
        toolInput: Any?,
        rawObject: [String: Any]?,
        transcriptPath: String?
    ) -> [String: Any]? {
        var context: [String: Any] = [:]

        if let rawContext = rawObject?["context"] as? [String: Any] {
            mergeFeedContext(&context, feedContext(from: rawContext))
        }

        if hookEventName == "UserPromptSubmit" {
            setFeedContext(
                &context,
                key: "lastUserMessage",
                value: feedPromptText(from: rawObject),
                maxLength: 1_000
            )
        }

        if let rawObject {
            setFeedContext(
                &context,
                key: "permissionMode",
                value: firstString(in: rawObject, keys: ["permissionMode", "permission_mode"]),
                maxLength: 80
            )
            setFeedContext(
                &context,
                key: "assistantPreamble",
                value: firstString(
                    in: rawObject,
                    keys: ["assistantPreamble", "assistant_preamble", "last_assistant_message", "lastAssistantMessage"]
                ),
                maxLength: 1_000
            )
        }

        if source == "claude",
           let transcriptPath,
           shouldReadTranscriptForFeedContext(hookEventName: hookEventName),
           let transcriptContext = readClaudeFeedContext(
                path: transcriptPath,
                matchingToolName: toolName
           ) {
            mergeFeedContext(&context, transcriptContext)
        }

        if let planContext = feedPlanContext(from: toolInput) {
            mergeFeedContext(&context, planContext, preferIncoming: true)
        }
        if let toolContext = feedToolContext(toolName: toolName, toolInput: toolInput) {
            mergeFeedContext(&context, toolContext)
        }

        return context.isEmpty ? nil : context
    }

    private func shouldReadTranscriptForFeedContext(hookEventName: String) -> Bool {
        switch hookEventName {
        case "PermissionRequest", "ExitPlanMode", "AskUserQuestion", "PreToolUse":
            return true
        default:
            return false
        }
    }

    func feedPromptText(from object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let direct = firstString(in: object, keys: ["prompt", "text", "message", "body"]) {
            return direct
        }
        for key in ["notification", "data"] {
            if let nested = object[key] as? [String: Any],
               let nestedPrompt = firstString(in: nested, keys: ["prompt", "text", "message", "body"]) {
                return nestedPrompt
            }
        }
        return nil
    }

    func feedWorkspaceId(rawObject: [String: Any]?, fallback: String?) -> String? {
        if let fallback {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let rawObject,
           let direct = firstString(
                in: rawObject,
                keys: ["workspace_id", "workspaceId", "workspace_ref", "workspaceRef"]
           ) {
            return direct
        }
        return nil
    }

    func agentPidForFeedSource(
        _ source: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        let envKey: String
        switch source {
        case "claude": envKey = "CMUX_CLAUDE_PID"
        case "codex": envKey = "CMUX_CODEX_PID"
        case "cursor": envKey = "CMUX_CURSOR_PID"
        case "gemini": envKey = "CMUX_GEMINI_PID"
        case "antigravity": envKey = "CMUX_ANTIGRAVITY_PID"
        case "rovodev": envKey = "CMUX_ROVODEV_PID"
        case "hermes-agent": envKey = "CMUX_HERMES_AGENT_PID"
        case "copilot": envKey = "CMUX_COPILOT_PID"
        case "kiro": envKey = "CMUX_KIRO_PID"
        default: envKey = ""
        }
        if !envKey.isEmpty,
           let rawPid = env[envKey],
           let pid = Int(rawPid),
           pid > 0 {
            return pid
        }
        return Int(getppid())
    }

    func stableFallbackFeedSessionId(
        source: String,
        rawObject: [String: Any],
        agentPid: Int
    ) -> String {
        var components = [
            "source=\(source)",
            "pid=\(max(agentPid, 0))",
        ]
        if let workspaceId = feedWorkspaceId(rawObject: rawObject, fallback: nil) {
            components.append("workspace=\(workspaceId)")
        }
        if let cwd = extractClaudeHookCWD(from: rawObject) {
            components.append("cwd=\(cwd)")
        }
        if let transcriptPath = extractHookTranscriptPath(from: rawObject) {
            components.append("transcript=\(transcriptPath)")
        }

        let seed = components.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(seed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "fallback-\(String(digest.prefix(16)))"
    }

    func enrichUserPromptSubmitFeedEvent(
        _ event: inout [String: Any],
        hookEventName: String,
        promptText: String?
    ) {
        guard hookEventName == "UserPromptSubmit",
              let promptText else { return }
        if var toolInput = event["tool_input"] as? [String: Any] {
            toolInput["prompt"] = promptText
            event["tool_input"] = toolInput
        } else {
            event["tool_input"] = ["prompt": promptText]
        }
        var context = event["context"] as? [String: Any] ?? [:]
        if context["lastUserMessage"] == nil {
            setFeedContext(
                &context,
                key: "lastUserMessage",
                value: promptText,
                maxLength: 1_000
            )
        }
        if !context.isEmpty {
            event["context"] = context
        }
    }

    private func feedContext(from raw: [String: Any]) -> [String: Any] {
        var context: [String: Any] = [:]
        setFeedContext(
            &context,
            key: "lastUserMessage",
            value: firstString(in: raw, keys: ["lastUserMessage", "last_user_message", "userPrompt", "prompt"]),
            maxLength: 1_000
        )
        setFeedContext(
            &context,
            key: "assistantPreamble",
            value: firstString(in: raw, keys: ["assistantPreamble", "assistant_preamble", "lastAssistantMessage", "last_assistant_message"]),
            maxLength: 1_000
        )
        setFeedContext(
            &context,
            key: "planSummary",
            value: firstString(in: raw, keys: ["planSummary", "plan_summary"]),
            maxLength: 600
        )
        setFeedContext(
            &context,
            key: "toolSummary",
            value: firstString(in: raw, keys: ["toolSummary", "tool_summary"]),
            maxLength: 600
        )
        setFeedContext(
            &context,
            key: "permissionMode",
            value: firstString(in: raw, keys: ["permissionMode", "permission_mode"]),
            maxLength: 80
        )
        let allowed = feedAllowedPrompts(from: raw["allowedPrompts"] ?? raw["allowed_prompts"])
        if !allowed.isEmpty {
            context["allowedPrompts"] = allowed
        }
        return context
    }

    private func readClaudeFeedContext(
        path: String,
        matchingToolName: String?
    ) -> [String: Any]? {
        guard let lines = readRecentTextFileLines(path: path, maxBytes: 1_048_576) else { return nil }

        var lastUserMessage: String?
        var lastAssistantText: String?
        var permissionMode: String?
        var matchedContext: [String: Any]?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            if let mode = firstString(in: obj, keys: ["permissionMode", "permission_mode"]) {
                permissionMode = mode
            }
            if let attachment = obj["attachment"] as? [String: Any],
               (attachment["type"] as? String) == "plan_mode" {
                permissionMode = "plan"
            }

            guard let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String
            else {
                continue
            }

            if role == "user" {
                if let text = extractMessageText(from: message) {
                    lastUserMessage = truncate(normalizedSingleLine(text), maxLength: 1_000)
                }
                continue
            }

            guard role == "assistant" else { continue }
            var messageText: String?
            if let text = extractMessageText(from: message) {
                messageText = truncate(normalizedSingleLine(text), maxLength: 1_000)
                lastAssistantText = messageText
            }

            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                guard (block["type"] as? String) == "tool_use" else { continue }
                let blockToolName = block["name"] as? String
                if let matchingToolName, blockToolName != matchingToolName {
                    continue
                }

                var context: [String: Any] = [:]
                setFeedContext(
                    &context,
                    key: "lastUserMessage",
                    value: lastUserMessage,
                    maxLength: 1_000
                )
                setFeedContext(
                    &context,
                    key: "assistantPreamble",
                    value: messageText ?? lastAssistantText,
                    maxLength: 1_000
                )
                setFeedContext(
                    &context,
                    key: "permissionMode",
                    value: permissionMode,
                    maxLength: 80
                )
                if let input = block["input"], let planContext = feedPlanContext(from: input) {
                    mergeFeedContext(&context, planContext, preferIncoming: true)
                }
                matchedContext = context
            }
        }

        if let matchedContext, !matchedContext.isEmpty {
            return matchedContext
        }

        var fallback: [String: Any] = [:]
        setFeedContext(&fallback, key: "lastUserMessage", value: lastUserMessage, maxLength: 1_000)
        setFeedContext(&fallback, key: "assistantPreamble", value: lastAssistantText, maxLength: 1_000)
        setFeedContext(&fallback, key: "permissionMode", value: permissionMode, maxLength: 80)
        return fallback.isEmpty ? nil : fallback
    }

    private func feedPlanContext(from rawToolInput: Any?) -> [String: Any]? {
        guard let dict = feedToolInputDictionary(rawToolInput),
              let plan = firstString(in: dict, keys: ["plan"])
        else {
            return nil
        }

        var context: [String: Any] = [:]
        setFeedContext(
            &context,
            key: "planSummary",
            value: feedPlanSummary(from: plan),
            maxLength: 600
        )
        let allowed = feedAllowedPrompts(from: dict["allowedPrompts"])
        if !allowed.isEmpty {
            context["allowedPrompts"] = allowed
        }
        return context.isEmpty ? nil : context
    }

    private func feedToolContext(toolName: String?, toolInput: Any?) -> [String: Any]? {
        guard let toolName, let dict = feedToolInputDictionary(toolInput) else { return nil }
        let lower = toolName.lowercased()
        var summary: String?
        if lower == "bash" {
            summary = firstString(in: dict, keys: ["description", "command"])
        } else if lower == "run_command" || lower == "execute_bash" || lower == "shell" {
            summary = firstString(in: dict, keys: ["CommandLine", "commandLine", "command", "Cwd", "cwd"])
        } else if ["write", "edit", "multiedit", "read", "fs_read", "fs_write"].contains(lower) {
            summary = firstString(in: dict, keys: ["file_path", "path"]) ?? firstOperationPath(in: dict)
        } else if ["view_file", "write_to_file", "replace_file_content", "multi_replace_file_content"].contains(lower) {
            summary = firstString(in: dict, keys: ["AbsolutePath", "TargetFile", "SearchPath", "DirectoryPath", "path"])
        } else if lower == "askuserquestion" || lower == "ask_question" {
            if let questions = dict["questions"] as? [[String: Any]],
               let first = questions.first {
                summary = firstString(in: first, keys: ["question", "prompt", "header"])
            } else {
                summary = firstString(in: dict, keys: ["question", "prompt"])
            }
        }
        guard let summary else { return nil }
        var context: [String: Any] = [:]
        setFeedContext(&context, key: "toolSummary", value: summary, maxLength: 600)
        return context.isEmpty ? nil : context
    }

    private func firstOperationPath(in dict: [String: Any]) -> String? {
        guard let operations = dict["operations"] as? [[String: Any]] else { return nil }
        for operation in operations {
            if let path = firstString(in: operation, keys: ["path", "file_path", "filePath"]) {
                return path
            }
        }
        return nil
    }

    private func feedToolInputDictionary(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] {
            return dict
        }
        if let json = raw as? String,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
           ) as? [String: Any] {
            return dict
        }
        return nil
    }

    private func feedAllowedPrompts(from raw: Any?) -> [[String: String]] {
        guard let raw else { return [] }
        if let rows = raw as? [[String: Any]] {
            return rows.compactMap { row in
                guard let prompt = firstString(in: row, keys: ["prompt", "description", "text"]) else {
                    return nil
                }
                var out = ["prompt": truncate(normalizedSingleLine(prompt), maxLength: 260)]
                if let tool = firstString(in: row, keys: ["tool", "toolName"]) {
                    out["tool"] = truncate(normalizedSingleLine(tool), maxLength: 80)
                }
                return out
            }
        }
        if let rows = raw as? [Any] {
            return rows.compactMap { row in
                if let text = row as? String {
                    let prompt = truncate(normalizedSingleLine(text), maxLength: 260)
                    return prompt.isEmpty ? nil : ["prompt": prompt]
                }
                guard let dict = row as? [String: Any] else { return nil }
                guard let prompt = firstString(in: dict, keys: ["prompt", "description", "text"]) else {
                    return nil
                }
                var out = ["prompt": truncate(normalizedSingleLine(prompt), maxLength: 260)]
                if let tool = firstString(in: dict, keys: ["tool", "toolName"]) {
                    out["tool"] = truncate(normalizedSingleLine(tool), maxLength: 80)
                }
                return out
            }
        }
        return []
    }

    private func feedPlanSummary(from plan: String) -> String? {
        var firstHeading: String?
        for rawLine in plan.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                if firstHeading == nil, !heading.isEmpty {
                    firstHeading = heading
                }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if let dot = line.firstIndex(of: "."),
               line[..<dot].allSatisfy(\.isNumber) {
                return String(line[line.index(after: dot)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            return line
        }
        return firstHeading
    }

    private func setFeedContext(
        _ context: inout [String: Any],
        key: String,
        value: String?,
        maxLength: Int
    ) {
        guard let value else { return }
        let normalized = normalizedSingleLine(value)
        guard !normalized.isEmpty else { return }
        context[key] = truncate(normalized, maxLength: maxLength)
    }

    private func mergeFeedContext(
        _ target: inout [String: Any],
        _ incoming: [String: Any],
        preferIncoming: Bool = false
    ) {
        for (key, value) in incoming {
            if preferIncoming || target[key] == nil {
                target[key] = value
            }
        }
    }

    private static func feedEventName(forClaudeSubcommand sub: String) -> String {
        switch sub {
        case "session-start", "active": return "SessionStart"
        case "prompt-submit": return "UserPromptSubmit"
        case "pre-tool-use", "cron-create-guard": return "PreToolUse"
        case "post-tool-use": return "PostToolUse"
        case "stop", "idle": return "Stop"
        case "session-end": return "SessionEnd"
        case "notification", "notify": return "Notification"
        default: return ""
        }
    }

    // MARK: - Feed history

}
