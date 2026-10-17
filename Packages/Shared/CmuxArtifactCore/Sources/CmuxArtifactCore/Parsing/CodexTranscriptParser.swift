import Foundation

/// Converts Codex CLI rollout JSONL lines into ``ChatMessage`` values.
///
/// Reads the format written under `~/.codex/sessions/YYYY/MM/DD/` as of
/// Codex CLI 0.139: every line is `{timestamp, type, payload}`. Content
/// lives in `response_item` payloads (`message`, `reasoning`,
/// `function_call`, `function_call_output`, `custom_tool_call`, ...), while
/// modern patch completions arrive as `event_msg` `patch_apply_end` payloads.
/// Other event messages, `turn_context`, and token bookkeeping are skipped.
/// The parser is stateless and fails open: malformed or unknown lines are
/// dropped silently. Pairing of calls with their `*_output` works across parse
/// calls through ``ChatTranscriptParseState``.
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
    static let shellWrapperBinaries: Set<String> = ["bash", "sh", "zsh"]
    private static let summaryArgumentKeys = [
        "path", "file_path", "pattern", "query", "url", "text", "key",
        "app", "session_id", "plan",
    ]

    private let budget = TranscriptTextBudget()
    private let timestamps = TranscriptTimestampParser()
    private let attachmentTokens = ChatAttachmentTokenExtractor()
    private let referencedPaths = ChatToolReferencedPathExtractor()
    let artifactText = ChatArtifactTextReferenceExtractor()

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
            case "event_msg":
                appendEventMessage(payload, seq: seq, timestamp: timestamp, into: &assembler)
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
            resolveOutput(payload, seq: seq, into: &assembler)
        case "web_search_call":
            appendWebSearch(payload, seq: seq, timestamp: timestamp, into: &assembler)
        default:
            return
        }
    }

    private func appendEventMessage(
        _ payload: TranscriptJSONValue?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        switch payload?["type"]?.string {
        case "patch_apply_end":
            appendEventTextArtifacts(payload, seq: seq, into: &assembler)
            appendPatchApplyEnd(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "agent_message":
            if let text = payload?["message"]?.string {
                assembler.appendArtifactReferences(paths: artifactText.paths(in: text), seq: seq)
            }
        case "exec_command_begin":
            appendEventTextArtifacts(payload, seq: seq, into: &assembler)
        case "exec_command_end", "exec_command_output_delta":
            appendEventTextArtifacts(payload, seq: seq, into: &assembler)
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
        for text in texts {
            assembler.appendArtifactReferences(paths: artifactText.paths(in: text), seq: seq)
        }
        if role == .user {
            appendUserTexts(texts, seq: seq, timestamp: timestamp, into: &assembler)
            return
        }
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

    private func appendUserTexts(
        _ texts: [String],
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        var emitted = 0
        for text in texts {
            let extraction = attachmentTokens.extractLeadingAttachments(from: text)
            for attachment in extraction.attachments {
                assembler.append(
                    ChatMessage(
                        id: blockID(lineID: "line-\(seq)", emitted: emitted),
                        seq: seq,
                        role: .user,
                        timestamp: timestamp,
                        kind: .attachment(attachment)
                    )
                )
                emitted += 1
            }
            let prose = extraction.remainingProse
            guard !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            assembler.append(
                ChatMessage(
                    id: blockID(lineID: "line-\(seq)", emitted: emitted),
                    seq: seq,
                    role: .user,
                    timestamp: timestamp,
                    kind: .prose(ChatProse(text: budget.body(prose)))
                )
            )
            emitted += 1
        }
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
        assembler.appendArtifactReferences(paths: artifactText.paths(in: text), seq: seq)
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

    private func appendPatchApplyEnd(
        _ payload: TranscriptJSONValue?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard payload?["success"]?.bool == true else { return }
        let changes = payload?["changes"]?.object ?? [:]
        let changedPaths = changes.keys.sorted()
        let movePaths = changedPaths.compactMap { changes[$0]?["move_path"]?.string }
        let paths = deduplicatedPaths(changedPaths + movePaths)
        var summary = "apply_patch"
        if let firstPath = changedPaths.first {
            summary += " \(budget.summaryArgument(firstPath))"
            if paths.count > 1 {
                summary += " (+\(paths.count - 1))"
            }
        }
        assembler.append(
            ChatMessage(
                id: payload?["call_id"]?.string ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "apply_patch",
                        summary: summary,
                        status: .succeeded,
                        referencedPaths: paths.isEmpty ? nil : paths
                    )
                )
            )
        )
    }

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
        // Codex's interactive picker is a `request_user_input` function call whose
        // arguments carry `questions[]` in the same shape as Claude's
        // AskUserQuestion. Render each as a tappable `.question` so the GUI shows
        // a real picker (wired to mobile.chat.answer) instead of plain text.
        if name == "request_user_input" {
            let questions = Self.codexQuestions(from: parsedArguments)
            if !questions.isEmpty {
                for (index, question) in questions.enumerated() {
                    let baseID = callID ?? "line-\(seq)"
                    assembler.append(
                        ChatMessage(
                            id: index == 0 ? baseID : "\(baseID)-q\(index)",
                            seq: seq,
                            role: .agent,
                            timestamp: timestamp,
                            kind: .question(question)
                        ),
                        // Pair with the request_user_input function_call_output by
                        // call id so the answer marks the question resolved (the
                        // GUI then shows the selection and stops being tappable).
                        pendingKey: index == 0 ? callID : nil
                    )
                }
                return
            }
        }
        let kind: ChatMessageKind
        if Self.shellToolNames.contains(name),
            let command = shellCommand(arguments: parsedArguments, payload: payload) {
            assembler.appendArtifactReferences(paths: artifactText.paths(in: command), seq: seq)
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

    /// Maps a `request_user_input` arguments object into tappable questions.
    /// Mirrors the Claude parser's question shape: `questions[].question` with
    /// `options[].label` and an optional `options[].description` detail.
    private static func codexQuestions(from arguments: TranscriptJSONValue?) -> [ChatQuestion] {
        let questions = arguments?["questions"]?.array ?? []
        return questions.compactMap { question -> ChatQuestion? in
            guard let prompt = question["question"]?.string else { return nil }
            let options = (question["options"]?.array ?? []).compactMap { option in
                option["label"]?.string.map {
                    ChatQuestion.Option(label: $0, detail: option["description"]?.string)
                }
            }
            guard !options.isEmpty else { return nil }
            return ChatQuestion(
                prompt: prompt,
                options: options,
                questionID: question["id"]?.string
            )
        }
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
        var patchReferencedPaths: [String]?
        if Self.isApplyPatchTool(name) {
            let paths = patchedFiles(in: input)
            if let path = paths.first {
                summary = "\(name) \(budget.summaryArgument(path))"
            }
            patchReferencedPaths = paths.isEmpty ? nil : paths
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
                        inputDetail: input.isEmpty ? nil : budget.inputDetail(input),
                        referencedPaths: patchReferencedPaths
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
        let structuredPaths = referencedPaths.referencedPaths(in: arguments) ?? []
        let patchPaths: [String]
        if Self.isApplyPatchTool(toolName) {
            let patch = arguments?["patch"]?.string
                ?? arguments?["input"]?.string
                ?? arguments?["patch_text"]?.string
                ?? ""
            patchPaths = patchedFiles(in: patch)
        } else {
            patchPaths = []
        }
        let allPaths = deduplicatedPaths(structuredPaths + patchPaths)
        return .toolUse(
            ChatToolUse(
                toolName: toolName,
                summary: summary,
                inputDetail: detail,
                referencedPaths: allPaths.isEmpty ? nil : allPaths
            )
        )
    }

}
