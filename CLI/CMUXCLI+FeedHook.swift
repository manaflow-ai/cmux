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


// MARK: - Feed hook bridge
extension CMUXCLI {
    /// Reads an agent hook JSON payload from stdin, forwards it to the
    /// running cmux app via the `feed.push` V2 socket verb, and (for
    /// actionable events: ExitPlanMode, AskUserQuestion, permission-
    /// requiring tools) blocks until the user resolves the item. The
    /// decision JSON is emitted on stdout in the agent's expected format
    /// so the agent honors the user's choice.
    ///
    /// Usage:
    ///   echo "<hook_json>" | cmux hooks feed --source <claude|codex|...>
    ///
    /// Designed so agents and wrappers can point a native decision hook
    /// at it and have permission/plan/question events surface in the
    /// Feed sidebar. Agent-specific lifecycle/status hooks can be
    /// chained separately. For Claude, `hooks claude pre-tool-use` is
    /// async status-only telemetry; blocking decisions come through
    /// PermissionRequest.
    func runFeedHook(
        commandArgs: [String],
        client: SocketClient? = nil,
        socketPath: String? = nil,
        socketPassword: String? = nil,
        telemetry: CLISocketSentryTelemetry
    ) throws {
        _ = telemetry
        let source = optionValue(commandArgs, name: "--source") ?? ""
        guard !source.isEmpty else {
            throw CLIError(message: "cmux hooks feed requires --source <agent-name>")
        }

        // Outside a cmux terminal (no CMUX_SURFACE_ID) → silently no-op.
        // Also matches the graceful-fallback pattern of the other hooks.
        guard ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]?.isEmpty == false else {
            print("{}")
            return
        }

        // Read stdin. Claude, Codex, and the other agents all pipe hook
        // JSON through stdin; unknown inputs fall through to `{}`.
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard !stdinData.isEmpty,
              let stdinObj = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]
        else {
            print("{}")
            return
        }

        // Derive the hook event name, mapped to our wire format. Claude
        // uses `hook_event_name`; Codex uses `event` or `hook_event_name`.
        let rawEvent = (stdinObj["hook_event_name"] as? String)
            ?? (stdinObj["event"] as? String)
            ?? optionValue(commandArgs, name: "--event")
            ?? ""
        let toolCall = stdinObj["toolCall"] as? [String: Any]
        let toolName = firstString(in: stdinObj, keys: ["tool_name", "toolName"])
            ?? toolCall.flatMap { firstString(in: $0, keys: ["name"]) }
            ?? ""

        // Decide whether this event is Feed-actionable. Non-actionable
        // events are forwarded as telemetry (non-blocking) and exit `{}`
        // so the agent proceeds without a decision.
        let (hookEventName, isActionable) = FeedEventClassifier.classify(
            source: source,
            event: rawEvent,
            toolName: toolName
        )
        let env = ProcessInfo.processInfo.environment
        if Self.shouldSuppressKiroFeedEvent(
            source: source,
            hookEventName: hookEventName,
            toolName: toolName,
            isActionable: isActionable,
            env: env
        ) {
            print("{}")
            return
        }

        // Capture the agent's PID (not our subprocess PID) so the
        // Feed can auto-expire pending cards when the agent is
        // killed/crashed. Agent wrappers export CMUX_<AGENT>_PID.
        // Other agents fall back to getppid() which walks up one
        // level — close enough to catch most kill scenarios.
        let agentPid = agentPidForFeedSource(source, env: env)
        let sessionId = firstString(
            in: stdinObj,
            keys: ["session_id", "sessionId", "conversation_id", "conversationId"]
        ) ?? stableFallbackFeedSessionId(source: source, rawObject: stdinObj, agentPid: agentPid)

        var eventDict: [String: Any] = [
            "session_id": "\(source)-\(sessionId)",
            "hook_event_name": hookEventName,
            "_source": source,
            "_ppid": agentPid,
        ]
        if let workspaceId = feedWorkspaceId(rawObject: stdinObj, fallback: env["CMUX_WORKSPACE_ID"]) {
            eventDict["workspace_id"] = workspaceId
        }
        let toolInput = stdinObj["tool_input"] ?? stdinObj["toolInput"] ?? toolCall?["args"]
        if let cwd = firstString(in: stdinObj, keys: ["cwd", "working_directory", "workingDirectory"])
            ?? firstWorkspacePath(in: stdinObj)
            ?? (toolInput as? [String: Any]).flatMap({ firstString(in: $0, keys: ["Cwd", "cwd"]) }) {
            eventDict["cwd"] = cwd
        }
        if !toolName.isEmpty { eventDict["tool_name"] = toolName }
        let promptText = hookEventName == "UserPromptSubmit" ? feedPromptText(from: stdinObj) : nil
        if let toolInput {
            eventDict["tool_input"] = toolInput
        }
        if let context = feedContextForEvent(
            source: source,
            hookEventName: hookEventName,
            toolName: toolName.isEmpty ? nil : toolName,
            toolInput: eventDict["tool_input"],
            rawObject: stdinObj,
            transcriptPath: firstString(in: stdinObj, keys: ["transcript_path", "transcriptPath"])
        ) {
            eventDict["context"] = context
        }
        enrichUserPromptSubmitFeedEvent(
            &eventDict,
            hookEventName: hookEventName,
            promptText: promptText
        )
        let requestId = stdinObj["_opencode_request_id"] as? String
            ?? firstString(in: stdinObj, keys: ["request_id", "tool_use_id", "toolUseID"])
            ?? "\(source)-\(sessionId)-\(rawEvent)-\(toolName)-\(Int(Date().timeIntervalSince1970 * 1000))"
        eventDict["_opencode_request_id"] = requestId

        // Sync. For actionable events we block up to 120s waiting
        // for the user's Feed click; the hook's stdout is then a
        // proper hookSpecificOutput that Claude honors directly
        // (no keystroke injection, no guessing the TUI layout).
        // If the user doesn't click in time the hook emits {}
        // and Claude falls back to its native TUI prompt.
        //
        // Wait is capped at 120s and the wrapper's hook timeout
        // is 125s so the socket always returns before Claude
        // would kill the hook subprocess itself.
        let waitTimeout: Double = isActionable ? 120 : 0
        let params: [String: Any] = [
            "event": eventDict,
            "wait_timeout_seconds": waitTimeout,
        ]

        var request: [String: Any] = [
            "method": "feed.push",
            "params": params,
        ]
        if waitTimeout > 0 {
            request["id"] = UUID().uuidString
        }
        let payload = try JSONSerialization.data(withJSONObject: request)
        let line = String(data: payload, encoding: .utf8) ?? "{}"

        if waitTimeout == 0 {
            if let client {
                _ = try? client.sendOneWay(command: line, writeTimeout: 0.05)
            } else if let socketPath {
                sendBestEffortFeedTelemetry(
                    socketPath: socketPath,
                    line: line,
                    socketPassword: socketPassword
                )
            }
            print("{}")
            return
        }

        var ownedClient: SocketClient?
        defer { ownedClient?.close() }
        let activeClient: SocketClient
        if let client {
            activeClient = client
        } else if let socketPath {
            let feedClient = SocketClient(path: socketPath)
            do {
                try feedClient.connect()
                try authenticateClientIfNeeded(
                    feedClient,
                    explicitPassword: socketPassword,
                    socketPath: socketPath
                )
            } catch {
                feedClient.close()
                print("{}")
                return
            }
            ownedClient = feedClient
            activeClient = feedClient
        } else {
            print("{}")
            return
        }

        let response: String
        do {
            response = try activeClient.send(
                command: line,
                responseTimeout: waitTimeout + 5
            )
        } catch {
            print("{}")
            return
        }

        guard let respData = response.data(using: .utf8),
              let respObj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let ok = respObj["ok"] as? Bool, ok,
              let result = respObj["result"] as? [String: Any]
        else {
            print("{}")
            return
        }

        let status = result["status"] as? String ?? "acknowledged"
        if status == "resolved", let decision = result["decision"] as? [String: Any] {
            if source == "kiro", Self.emitKiroDecisionIfHandled(decision: decision) {
                return
            }
            let out = Self.renderAgentDecision(
                source: source,
                hookEventName: hookEventName,
                toolName: toolName,
                toolInput: eventDict["tool_input"],
                rawObject: stdinObj,
                decision: decision
            )
            print(out)
            return
        }
        print("{}")
    }

    private static func shouldSuppressKiroFeedEvent(
        source: String,
        hookEventName: String,
        toolName: String,
        isActionable: Bool,
        env: [String: String]
    ) -> Bool {
        guard source == "kiro" else { return false }
        guard env["CMUX_KIRO_NOTIFICATION_LEVEL"] != nil || hookEventName == "PreToolUse" || hookEventName == "PostToolUse" else {
            return false
        }
        guard !isActionable else { return false }
        let level = env["CMUX_KIRO_NOTIFICATION_LEVEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "standard"
        switch level {
        case "minimal":
            return hookEventName == "PreToolUse" || hookEventName == "PostToolUse"
        case "verbose":
            return false
        default:
            if hookEventName == "PreToolUse" || hookEventName == "PostToolUse" {
                return !FeedEventClassifier.isSideEffectingTool(toolName, source: source)
            }
            return false
        }
    }

    private static func emitKiroDecisionIfHandled(decision: [String: Any]) -> Bool {
        guard (decision["kind"] as? String) == "permission" else { return false }
        let mode = (decision["mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Feed permission decisions carry a WorkstreamPermissionMode raw value:
        // `once` / `always` / `all` / `bypass` all allow the tool; `deny`
        // blocks. Fail closed on anything else — missing, empty, or an
        // unrecognized/typo mode — so a malformed decision blocks the tool
        // (exit 2 is Kiro's preToolUse deny signal) rather than silently
        // allowing work the user never approved.
        let allowModes: Set<String> = ["once", "always", "all", "bypass"]
        if let mode, allowModes.contains(mode) {
            print("{}")
            return true
        }
        if mode == "deny" {
            fputs("User denied permission via cmux Feed.\n", stderr)
        } else {
            fputs("cmux Feed returned an unrecognized Kiro permission decision; denying for safety.\n", stderr)
        }
        fflush(stderr)
        exit(2)
    }

    private static let skipInterviewAndPlanAnswer = "Skip interview and plan immediately"

    /// Encodes the user's decision in the agent's expected hook stdout
    /// shape so the agent honors it.
    private static func renderAgentDecision(
        source: String,
        hookEventName: String,
        toolName: String,
        toolInput: Any?,
        rawObject: [String: Any],
        decision: [String: Any]
    ) -> String {
        let kind = decision["kind"] as? String ?? ""

        func encode(_ obj: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.sortedKeys]
            ),
                  let s = String(data: data, encoding: .utf8)
            else { return "{}" }
            return s
        }

        func permissionRequestHookDecision(
            behavior: String,
            message: String? = nil,
            updatedInput: [String: Any]? = nil,
            updatedPermissions: [[String: Any]]? = nil
        ) -> [String: Any] {
            var inner: [String: Any] = ["behavior": behavior]
            if behavior == "deny" {
                inner["message"] = message ?? "User denied permission via cmux Feed."
            }
            if let updatedInput, !updatedInput.isEmpty {
                inner["updatedInput"] = updatedInput
            }
            if let updatedPermissions, !updatedPermissions.isEmpty {
                inner["updatedPermissions"] = updatedPermissions
            }
            return [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": inner,
                ]
            ]
        }

        // PreToolUse output for non-Claude agents that still use a
        // PreToolUse-compatible permission bridge. Claude Code does not
        // use this path.
        func nonClaudePreToolDecision(
            permission: String,
            reason: String?,
            additionalContext: String? = nil,
            updatedInput: [String: Any]? = nil
        ) -> [String: Any] {
            var specific: [String: Any] = [
                "hookEventName": "PreToolUse",
                "permissionDecision": permission,
            ]
            if let reason, !reason.isEmpty {
                specific["permissionDecisionReason"] = reason
            }
            if let additionalContext, !additionalContext.isEmpty {
                specific["additionalContext"] = additionalContext
            }
            if let updatedInput, !updatedInput.isEmpty {
                specific["updatedInput"] = updatedInput
            }
            var out: [String: Any] = [
                "hookSpecificOutput": specific
            ]
            if permission == "deny" {
                out["decision"] = "block"
                if let reason, !reason.isEmpty { out["reason"] = reason }
            } else if permission == "allow" {
                out["decision"] = "approve"
                if let additionalContext, !additionalContext.isEmpty {
                    out["systemMessage"] = additionalContext
                } else if let reason, !reason.isEmpty {
                    out["systemMessage"] = reason
                }
            }
            return out
        }

        func hermesAgentBlock(_ message: String) -> String {
            encode(["action": "block", "message": message])
        }

        switch kind {
        case "permission":
            let mode = decision["mode"] as? String ?? "deny"
            if source == "claude" {
                if mode == "deny" {
                    return encode(permissionRequestHookDecision(
                        behavior: "deny",
                        message: "User denied permission via cmux Feed."
                    ))
                }
                var updatedPermissions: [[String: Any]]?
                if mode == "always" || mode == "all" {
                    updatedPermissions = rawObject["permission_suggestions"] as? [[String: Any]]
                }
                return encode(permissionRequestHookDecision(
                    behavior: "allow",
                    updatedPermissions: updatedPermissions
                ))
            }
            if source == "codex" {
                if mode == "deny" {
                    return encode(permissionRequestHookDecision(
                        behavior: "deny",
                        message: "User denied permission via cmux Feed."
                    ))
                }
                return encode(permissionRequestHookDecision(behavior: "allow"))
            }
            if source == "hermes-agent" {
                if mode == "deny" {
                    return hermesAgentBlock("User denied permission via cmux Feed.")
                }
                return "{}"
            }
            if source == "antigravity" {
                let reason = mode == "deny"
                    ? "User denied permission via cmux Feed."
                    : "User approved via cmux Feed."
                return encode([
                    "decision": mode == "deny" ? "deny" : "allow",
                    "reason": reason,
                ])
            }
            if mode == "deny" {
                return encode(nonClaudePreToolDecision(
                    permission: "deny",
                    reason: "User denied permission via cmux Feed."
                ))
            }
            var reasonText = "User approved via cmux Feed."
            if mode == "always" || mode == "all" || mode == "bypass" {
                reasonText = "User granted \(mode) permission via cmux Feed. Reduce subsequent approval prompts for similar calls."
            }
            return encode(nonClaudePreToolDecision(
                permission: "allow",
                reason: reasonText
            ))

        case "exit_plan":
            let mode = decision["mode"] as? String ?? "manual"
            let feedback = (decision["feedback"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if source == "claude" {
                if let feedback, !feedback.isEmpty {
                    return encode(permissionRequestHookDecision(
                        behavior: "deny",
                        message: "User rejected the plan via cmux Feed and wants this change: \(feedback)"
                    ))
                }
                if mode == "deny" {
                    return encode(permissionRequestHookDecision(
                        behavior: "deny",
                        message: "User rejected the plan via cmux Feed."
                    ))
                }
                if mode == "ultraplan" {
                    return encode(permissionRequestHookDecision(
                        behavior: "deny",
                        message: "User chose Ultraplan via cmux Feed. Refine this plan with Ultraplan on Claude Code on the web."
                    ))
                }
                var updatedPermissions: [[String: Any]]?
                if mode == "autoAccept" {
                    updatedPermissions = [[
                        "type": "setMode",
                        "mode": "auto",
                        "destination": "session",
                    ]]
                }
                return encode(permissionRequestHookDecision(
                    behavior: "allow",
                    updatedInput: jsonDictionary(from: toolInput),
                    updatedPermissions: updatedPermissions
                ))
            }
            if source == "hermes-agent" {
                if let feedback, !feedback.isEmpty {
                    return hermesAgentBlock("User rejected the plan via cmux Feed and wants this change: \(feedback)")
                }
                if mode == "deny" {
                    return hermesAgentBlock("User rejected the plan via cmux Feed.")
                }
                return "{}"
            }
            if let feedback, !feedback.isEmpty {
                let reason = "User rejected the plan via cmux Feed and wants this change: \(feedback)"
                return encode(nonClaudePreToolDecision(
                    permission: "deny",
                    reason: reason,
                    additionalContext: reason
                ))
            }
            if mode == "deny" {
                return encode(nonClaudePreToolDecision(
                    permission: "deny",
                    reason: "User rejected the plan via cmux Feed."
                ))
            }
            if mode == "ultraplan" {
                let reason = "User chose Ultraplan via cmux Feed. Refine this plan with Ultraplan if available."
                return encode(nonClaudePreToolDecision(
                    permission: "deny",
                    reason: reason,
                    additionalContext: reason
                ))
            }
            let modeText: String
            switch mode {
            case "bypassPermissions":
                modeText = "bypass-permissions mode (no per-edit approval)"
            case "autoAccept":
                modeText = "auto mode"
            default:
                modeText = "manual-approval mode (approve each edit)"
            }
            let ctx = "User accepted this plan via cmux Feed with \(modeText). Exit plan mode now and proceed to implement without re-entering ExitPlanMode. Do not ask again."
            return encode(nonClaudePreToolDecision(
                permission: "deny",
                reason: ctx,
                additionalContext: ctx
            ))

        case "question":
            let selections = decision["selections"] as? [String] ?? []
            if selections == [Self.skipInterviewAndPlanAnswer] {
                let message = "User chose Skip interview and plan immediately via cmux Feed. Do not ask more interview questions. Write the plan now."
                if source == "claude" {
                    return encode(permissionRequestHookDecision(
                        behavior: "deny",
                        message: message
                    ))
                }
                return encode(nonClaudePreToolDecision(
                    permission: "deny",
                    reason: message,
                    additionalContext: message
                ))
            }
            if source == "hermes-agent" {
                let body: String
                if selections.isEmpty {
                    body = "The user submitted an empty answer."
                } else if selections.count == 1 {
                    body = "The user answered: \(selections[0])"
                } else {
                    body = "The user answered: \(selections.joined(separator: ", "))"
                }
                return encode(["context": body])
            }
            if source == "claude" {
                let updatedInput = claudeAskUserQuestionInput(
                    toolInput: toolInput,
                    selections: selections
                )
                return encode(permissionRequestHookDecision(
                    behavior: "allow",
                    updatedInput: updatedInput
                ))
            }
            let body: String
            if selections.isEmpty {
                body = "The user submitted an empty answer."
            } else if selections.count == 1 {
                body = "The user answered: \(selections[0])"
            } else {
                let lines = selections
                    .enumerated()
                    .map { idx, s in "\(idx + 1). \(s)" }
                    .joined(separator: "\n")
                body = "The user answered:\n\(lines)"
            }
            let ctx = "[cmux Feed] \(body). Treat these as the user's response to your AskUserQuestion prompt; do not call AskUserQuestion again for the same question."
            return encode(nonClaudePreToolDecision(
                permission: "deny",
                reason: ctx,
                additionalContext: ctx
            ))

        default:
            _ = hookEventName
            _ = toolName
            return "{}"
        }
    }

    private static func jsonDictionary(from raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        if let str = raw as? String,
           let data = str.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return nil
    }

    private static func claudeAskUserQuestionInput(
        toolInput: Any?,
        selections: [String]
    ) -> [String: Any] {
        var input = jsonDictionary(from: toolInput) ?? [:]
        let questions = input["questions"] as? [[String: Any]] ?? []
        var answers: [String: String] = [:]
        for (idx, selection) in selections.enumerated() {
            let key: String
            if idx < questions.count,
               let question = questions[idx]["question"] as? String,
               !question.isEmpty {
                key = question
            } else {
                key = "Answer \(idx + 1)"
            }
            answers[key] = selection
        }
        input["answers"] = answers
        return input
    }

    // MARK: Convenience wrappers

}
