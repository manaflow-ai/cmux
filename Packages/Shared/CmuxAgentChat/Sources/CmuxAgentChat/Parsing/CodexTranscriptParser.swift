import Foundation

/// Converts Codex CLI rollout JSONL lines into ``ChatMessage`` values.
///
/// Reads the format written under `~/.codex/sessions/YYYY/MM/DD/` as of
/// Codex CLI 0.139: every line is `{timestamp, type, payload}`. Content
/// lives in `response_item` payloads (`message`, `reasoning`,
/// `function_call`, `function_call_output`, `custom_tool_call`, ...);
/// `event_msg`, `turn_context`, and token bookkeeping are skipped. The
/// parser is stateless and fails open: malformed or unknown lines are
/// dropped silently. Pairing of calls with their `*_output` works across
/// parse calls through ``ChatTranscriptParseState``.
public struct CodexTranscriptParser: Sendable {
    private static let userNoisePrefixes = [
        "<user_instructions",
        "<environment_context",
        "<permissions",
        "<collaboration_mode",
        "<turn_aborted",
        "# AGENTS.md instructions",
    ]
    private static let shellToolNames: Set<String> = [
        "shell", "exec_command", "local_shell_call", "container.exec",
    ]
    private static let shellWrapperBinaries: Set<String> = ["bash", "sh", "zsh"]
    private static let summaryArgumentKeys = [
        "path", "file_path", "pattern", "query", "url", "text", "key",
        "app", "session_id", "plan",
    ]

    private let budget = TranscriptTextBudget()
    private let timestamps = TranscriptTimestampParser()

    /// Creates a Codex transcript parser.
    public init() {}

    /// Parses a contiguous run of JSONL lines into chat messages.
    ///
    /// - Parameters:
    ///   - lines: The raw JSONL lines, one rollout line each.
    ///   - startingSeq: The absolute line index of the first input line;
    ///     each parsed message gets `seq == startingSeq + lineOffset`.
    ///   - state: Carry-over state from the previous parse call.
    /// - Returns: The new messages, updates to earlier messages whose tool
    ///   output arrived in this call, and the next carry-over state.
    public func parse(
        lines: some Sequence<String>,
        startingSeq: Int,
        state: ChatTranscriptParseState = ChatTranscriptParseState()
    ) -> ChatTranscriptParseResult {
        var assembler = TranscriptBatchAssembler(state: state, budget: budget)
        var lastTimestamp = state.lastTimestamp
        for (offset, line) in lines.enumerated() {
            let seq = startingSeq + offset
            guard let root = TranscriptJSONValue(jsonLine: line), root.object != nil else {
                continue
            }
            if let stamped = timestamps.date(from: root["timestamp"]?.string) {
                lastTimestamp = stamped
            }
            let timestamp = lastTimestamp ?? Date(timeIntervalSince1970: 0)
            let payload = root["payload"]
            switch root["type"]?.string {
            case "session_meta":
                appendSessionStart(payload, seq: seq, timestamp: timestamp, into: &assembler)
            case "compacted":
                assembler.append(
                    ChatMessage(
                        id: "line-\(seq)",
                        seq: seq,
                        role: .system,
                        timestamp: timestamp,
                        kind: .status(ChatStatusTransition(event: .contextCompacted))
                    )
                )
            case "response_item":
                appendResponseItem(payload, seq: seq, timestamp: timestamp, into: &assembler)
            default:
                continue
            }
        }
        return assembler.result(lastTimestamp: lastTimestamp)
    }

    // MARK: - Line kinds

    private func appendSessionStart(
        _ payload: TranscriptJSONValue?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let sessionID = payload?["id"]?.string
        assembler.append(
            ChatMessage(
                id: sessionID.map { "session-\($0)" } ?? "line-\(seq)",
                seq: seq,
                role: .system,
                timestamp: timestamp,
                kind: .status(
                    ChatStatusTransition(
                        event: .sessionStarted,
                        detail: payload?["cwd"]?.string
                    )
                )
            )
        )
    }

    private func appendResponseItem(
        _ payload: TranscriptJSONValue?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let payload else { return }
        switch payload["type"]?.string {
        case "message":
            appendMessage(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "reasoning":
            appendReasoning(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "function_call":
            appendFunctionCall(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "custom_tool_call":
            appendCustomToolCall(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "function_call_output", "custom_tool_call_output":
            resolveOutput(payload, into: &assembler)
        case "web_search_call":
            appendWebSearch(payload, seq: seq, timestamp: timestamp, into: &assembler)
        default:
            return
        }
    }

    private func appendMessage(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let role: ChatRole
        switch payload["role"]?.string {
        case "user": role = .user
        case "assistant": role = .agent
        default: return  // developer / system context injections
        }
        let blocks = payload["content"]?.array ?? []
        let texts = blocks.compactMap { block -> String? in
            guard
                let type = block["type"]?.string,
                type == "input_text" || type == "output_text",
                let text = block["text"]?.string
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if role == .user,
                Self.userNoisePrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                return nil
            }
            return text
        }
        guard !texts.isEmpty else { return }
        assembler.append(
            ChatMessage(
                id: "line-\(seq)",
                seq: seq,
                role: role,
                timestamp: timestamp,
                kind: .prose(ChatProse(text: budget.body(texts.joined(separator: "\n\n"))))
            )
        )
    }

    private func appendReasoning(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let summaries = (payload["summary"]?.array ?? []).compactMap { item in
            item["text"]?.string
        }
        let text = summaries.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assembler.append(
            ChatMessage(
                id: "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .thought(ChatThought(text: budget.body(text)))
            )
        )
    }

    // MARK: - Tool calls

    private func appendFunctionCall(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let name = payload["name"]?.string else { return }
        let callID = payload["call_id"]?.string
        let arguments = payload["arguments"]?.string
        let parsedArguments = arguments.flatMap { TranscriptJSONValue(jsonLine: $0) }
        let kind: ChatMessageKind
        if Self.shellToolNames.contains(name),
            let command = shellCommand(arguments: parsedArguments, payload: payload) {
            kind = .terminal(ChatTerminalCapture(command: command, isRunning: true))
        } else {
            kind = genericToolUseKind(
                toolName: name,
                arguments: parsedArguments,
                rawArguments: arguments
            )
        }
        assembler.append(
            ChatMessage(
                id: callID ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: kind
            ),
            pendingKey: callID
        )
    }

    private func appendCustomToolCall(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let name = payload["name"]?.string else { return }
        let callID = payload["call_id"]?.string
        let input = payload["input"]?.string ?? ""
        var summary = name
        if name == "apply_patch", let path = firstPatchedFile(in: input) {
            summary = "\(name) \(budget.summaryArgument(path))"
        }
        assembler.append(
            ChatMessage(
                id: callID ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: name,
                        summary: summary,
                        inputDetail: input.isEmpty ? nil : budget.inputDetail(input)
                    )
                )
            ),
            pendingKey: callID
        )
    }

    private func appendWebSearch(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let query = payload["action"]?["query"]?.string else { return }
        assembler.append(
            ChatMessage(
                id: "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "web_search",
                        summary: "Search \(budget.summaryArgument(query))",
                        status: .succeeded
                    )
                )
            )
        )
    }

    private func genericToolUseKind(
        toolName: String,
        arguments: TranscriptJSONValue?,
        rawArguments: String?
    ) -> ChatMessageKind {
        var summary = toolName
        if let arguments {
            for key in Self.summaryArgumentKeys {
                if let value = arguments[key]?.string,
                    !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    summary = "\(toolName) \(budget.summaryArgument(value))"
                    break
                }
            }
        }
        let detail = rawArguments.flatMap { raw -> String? in
            raw.isEmpty || raw == "{}" ? nil : budget.inputDetail(raw)
        }
        return .toolUse(
            ChatToolUse(toolName: toolName, summary: summary, inputDetail: detail)
        )
    }

    /// Extracts the human-meaningful command line from a shell-style call.
    ///
    /// Handles `{"cmd": "..."}` (current `exec_command`), `{"command":
    /// "..."}`, and `{"command": ["bash", "-lc", "actual"]}` (older
    /// `shell`), plus the `local_shell_call` `action.command` array.
    private func shellCommand(
        arguments: TranscriptJSONValue?,
        payload: TranscriptJSONValue
    ) -> String? {
        if let cmd = arguments?["cmd"]?.string { return cmd }
        if let cmd = arguments?["command"]?.string { return cmd }
        let parts = arguments?["command"]?.array ?? payload["action"]?["command"]?.array
        guard let parts else { return nil }
        let strings = parts.compactMap(\.string)
        guard !strings.isEmpty else { return nil }
        if strings.count >= 3,
            let binary = strings[0].split(separator: "/").last,
            Self.shellWrapperBinaries.contains(String(binary)),
            strings[1] == "-lc" || strings[1] == "-c" {
            return strings[2...].joined(separator: " ")
        }
        return strings.joined(separator: " ")
    }

    private func firstPatchedFile(in patch: String) -> String? {
        guard
            let match = patch.firstMatch(
                of: /\*\*\* (?:Update|Add|Delete) File: (.+)/
            )
        else { return nil }
        return String(match.1)
    }

    // MARK: - Tool outputs

    private func resolveOutput(
        _ payload: TranscriptJSONValue,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let callID = payload["call_id"]?.string else { return }
        assembler.resolve(key: callID, completion: completion(from: payload["output"]))
    }

    /// Builds a completion from an output payload, which is a plain string,
    /// a JSON-encoded `{"output": ..., "metadata": {"exit_code": ...}}`
    /// string, or that object inline; exit code and wall time also appear
    /// as text headers (`Process exited with code N`, `Exit code: N`,
    /// `Wall time: S seconds`).
    private func completion(from value: TranscriptJSONValue?) -> TranscriptToolCompletion {
        var text = value?.string
        var exitCode = value?["metadata"]?["exit_code"]?.int
        var duration = value?["metadata"]?["duration_seconds"]?.double
        if text == nil, value?.object != nil {
            text = value?["output"]?.string
        }
        if let raw = text,
            let nested = TranscriptJSONValue(jsonLine: raw),
            let inner = nested["output"]?.string {
            text = inner
            exitCode = nested["metadata"]?["exit_code"]?.int ?? exitCode
            duration = nested["metadata"]?["duration_seconds"]?.double ?? duration
        }
        if exitCode == nil, let text {
            let head = text.prefix(400)
            if let match = head.firstMatch(
                of: /(?:Process exited with code|Exit code:?|exited with code) (-?\d+)/
            ) {
                exitCode = Int(match.1)
            }
        }
        if duration == nil, let text,
            let match = text.prefix(400).firstMatch(of: /Wall time: ([0-9.]+) seconds/) {
            duration = Double(match.1)
        }
        return TranscriptToolCompletion(
            output: text,
            isError: (exitCode ?? 0) != 0,
            exitCode: exitCode,
            durationSeconds: duration
        )
    }
}
