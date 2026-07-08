import Foundation

/// Converts Claude Code session JSONL lines into ``ChatMessage`` values.
///
/// Reads the format written under `~/.claude/projects/<encoded-cwd>/` as of
/// Claude Code 2.1: `user` and `assistant` lines carry content; everything
/// else (`mode`, `file-history-snapshot`, `attachment`, `system`,
/// `last-prompt`, `ai-title`, `queue-operation`, ...) is skipped. The
/// parser is stateless and fails open: malformed or unknown lines are
/// dropped silently. Pairing of `tool_use` blocks with their later
/// `tool_result` works across parse calls through
/// ``ChatTranscriptParseState``.
public struct ClaudeTranscriptParser: Sendable {
    private static let userNoisePrefixes = [
        "<command-name>",
        "<local-command",
        "<system-reminder",
    ]
    private static let editToolNames: Set<String> = ["Edit", "MultiEdit", "NotebookEdit"]
    private static let summaryArgumentKeys = [
        "file_path", "notebook_path", "path", "pattern", "command", "query",
        "url", "description", "prompt", "skill", "name",
    ]

    private let budget = TranscriptTextBudget()
    private let timestamps = TranscriptTimestampParser()
    private let diffs = TranscriptDiffBuilder()
    private let attachmentTokens = ChatAttachmentTokenExtractor()
    private let referencedPaths = ChatToolReferencedPathExtractor()

    /// Creates a Claude transcript parser.
    public init() {}

    /// Parses a contiguous run of JSONL lines into chat messages.
    ///
    /// - Parameters:
    ///   - lines: The raw JSONL lines, one transcript line each.
    ///   - startingSeq: The absolute line index of the first input line;
    ///     each parsed message gets `seq == startingSeq + lineOffset`.
    ///   - state: Carry-over state from the previous parse call.
    /// - Returns: The new messages, updates to earlier messages whose tool
    ///   result arrived in this call, and the next carry-over state.
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
            // Task-subagent traffic shares the session JSONL with
            // `isSidechain: true`; its "user" lines are injected prompts the
            // human never typed. Skip them BEFORE touching lastTimestamp
            // (the seq is still consumed, so line indexing never drifts),
            // so a subagent line's timestamp can't leak into a later
            // visible line that lacks one.
            if root["isSidechain"]?.bool == true {
                continue
            }
            if let stamped = timestamps.date(from: root["timestamp"]?.string) {
                lastTimestamp = stamped
            }
            let timestamp = lastTimestamp ?? Date(timeIntervalSince1970: 0)
            switch root["type"]?.string {
            case "user":
                appendUserLine(root, seq: seq, timestamp: timestamp, into: &assembler)
            case "assistant":
                appendAssistantLine(root, seq: seq, timestamp: timestamp, into: &assembler)
            default:
                continue
            }
        }
        return assembler.result(lastTimestamp: lastTimestamp)
    }

    // MARK: - User lines

    private func appendUserLine(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard root["isMeta"]?.bool != true else { return }
        guard let content = root["message"]?["content"] else { return }
        let lineID = root["uuid"]?.string ?? "line-\(seq)"
        var emitted = 0
        if let text = content.string {
            appendUserProse(
                text, lineID: lineID, emitted: &emitted, seq: seq,
                timestamp: timestamp, into: &assembler
            )
            return
        }
        for block in content.array ?? [] {
            switch block["type"]?.string {
            case "text":
                appendUserProse(
                    block["text"]?.string ?? "", lineID: lineID, emitted: &emitted,
                    seq: seq, timestamp: timestamp, into: &assembler
                )
            case "tool_result":
                resolveToolResult(block, into: &assembler)
            default:
                continue
            }
        }
    }

    private func appendUserProse(
        _ text: String,
        lineID: String,
        emitted: inout Int,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !Self.userNoisePrefixes.contains(where: { trimmed.hasPrefix($0) }) else { return }
        let extraction = attachmentTokens.extractLeadingAttachments(from: text)
        for attachment in extraction.attachments {
            assembler.append(
                ChatMessage(
                    id: blockID(lineID: lineID, emitted: emitted),
                    seq: seq,
                    role: .user,
                    timestamp: timestamp,
                    kind: .attachment(attachment)
                )
            )
            emitted += 1
        }
        let prose = extraction.remainingProse
        guard !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assembler.append(
            ChatMessage(
                id: blockID(lineID: lineID, emitted: emitted),
                seq: seq,
                role: .user,
                timestamp: timestamp,
                kind: .prose(ChatProse(text: budget.body(prose)))
            )
        )
        emitted += 1
    }

    private func resolveToolResult(
        _ block: TranscriptJSONValue,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let callID = block["tool_use_id"]?.string else { return }
        let output = resultText(from: block["content"])
        let isError = block["is_error"]?.bool ?? false
        assembler.resolve(
            key: callID,
            completion: TranscriptToolCompletion(
                output: output,
                isError: isError,
                exitCode: parsedExitCode(from: output)
            )
        )
    }

    /// Extracts text from a `tool_result` content payload, which is either
    /// a plain string or an array of blocks where only `text` blocks carry
    /// renderable text.
    private func resultText(from content: TranscriptJSONValue?) -> String? {
        if let text = content?.string { return text }
        guard let blocks = content?.array else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"]?.string == "text" else { return nil }
            return block["text"]?.string
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private func parsedExitCode(from output: String?) -> Int? {
        guard let output else { return nil }
        let head = output.prefix(200)
        guard let match = head.firstMatch(of: /Exit code:? (-?\d+)/) else { return nil }
        return Int(match.1)
    }

    // MARK: - Assistant lines

    private func appendAssistantLine(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let content = root["message"]?["content"] else { return }
        let lineID = root["uuid"]?.string ?? "line-\(seq)"
        var emitted = 0
        if let text = content.string {
            appendAgentProse(
                text, lineID: lineID, emitted: &emitted, seq: seq,
                timestamp: timestamp, into: &assembler
            )
            return
        }
        for block in content.array ?? [] {
            switch block["type"]?.string {
            case "text":
                appendAgentProse(
                    block["text"]?.string ?? "", lineID: lineID, emitted: &emitted,
                    seq: seq, timestamp: timestamp, into: &assembler
                )
            case "thinking":
                appendThought(
                    block["thinking"]?.string ?? "", lineID: lineID, emitted: &emitted,
                    seq: seq, timestamp: timestamp, into: &assembler
                )
            case "tool_use":
                appendToolUse(
                    block, lineID: lineID, emitted: &emitted, seq: seq,
                    timestamp: timestamp, into: &assembler
                )
            default:
                continue
            }
        }
    }

    private func appendAgentProse(
        _ text: String,
        lineID: String,
        emitted: inout Int,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assembler.append(
            ChatMessage(
                id: blockID(lineID: lineID, emitted: emitted),
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .prose(ChatProse(text: budget.body(text)))
            )
        )
        emitted += 1
    }

    private func appendThought(
        _ text: String,
        lineID: String,
        emitted: inout Int,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assembler.append(
            ChatMessage(
                id: blockID(lineID: lineID, emitted: emitted),
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .thought(ChatThought(text: budget.body(text)))
            )
        )
        emitted += 1
    }

    // MARK: - Tool use blocks

    private func appendToolUse(
        _ block: TranscriptJSONValue,
        lineID: String,
        emitted: inout Int,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let toolName = block["name"]?.string else { return }
        let callID = block["id"]?.string
        let input = block["input"]
        let kinds = toolUseKinds(toolName: toolName, input: input)
        for kind in kinds {
            let message = ChatMessage(
                id: blockID(lineID: lineID, emitted: emitted),
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: kind
            )
            // Register every emitted message under the call id so the
            // result resolves all of them (a multi-question
            // AskUserQuestion emits one card per question, each resolved by
            // its own prompt).
            assembler.append(message, pendingKey: callID)
            emitted += 1
        }
    }

    /// Maps one `tool_use` block to its message payload(s).
    private func toolUseKinds(
        toolName: String,
        input: TranscriptJSONValue?
    ) -> [ChatMessageKind] {
        if toolName == "Bash", let command = input?["command"]?.string {
            return [.terminal(ChatTerminalCapture(command: command, isRunning: true))]
        }
        if toolName == "Write" || Self.editToolNames.contains(toolName) {
            if let edit = fileEditKind(toolName: toolName, input: input) {
                return [edit]
            }
        }
        if toolName == "AskUserQuestion" {
            let questions = questionKinds(input: input)
            if !questions.isEmpty { return questions }
        }
        return [genericToolUseKind(toolName: toolName, input: input)]
    }

    private func fileEditKind(
        toolName: String,
        input: TranscriptJSONValue?
    ) -> ChatMessageKind? {
        guard let input else { return nil }
        guard
            let filePath = input["file_path"]?.string ?? input["notebook_path"]?.string
        else { return nil }
        let change: TranscriptDiffBuilder.Change
        let operation: ChatFileEdit.Operation
        switch toolName {
        case "Write":
            operation = .write
            change = diffs.creation(content: input["content"]?.string ?? "")
        case "MultiEdit":
            operation = .edit
            let edits = (input["edits"]?.array ?? []).map { edit in
                diffs.replacement(
                    oldText: edit["old_string"]?.string ?? "",
                    newText: edit["new_string"]?.string ?? ""
                )
            }
            change = diffs.combined(edits)
        default:
            operation = .edit
            change = diffs.replacement(
                oldText: input["old_string"]?.string ?? "",
                newText: input["new_string"]?.string ?? input["new_source"]?.string ?? ""
            )
        }
        return .fileEdit(
            ChatFileEdit(
                filePath: filePath,
                operation: operation,
                additions: change.additions,
                deletions: change.deletions,
                unifiedDiff: change.diff.isEmpty ? nil : budget.body(change.diff)
            )
        )
    }

    private func questionKinds(input: TranscriptJSONValue?) -> [ChatMessageKind] {
        let questions = input?["questions"]?.array ?? []
        return questions.compactMap { question -> ChatMessageKind? in
            guard let prompt = question["question"]?.string else { return nil }
            let options = (question["options"]?.array ?? []).compactMap { option in
                option["label"]?.string.map {
                    ChatQuestion.Option(label: $0, detail: option["description"]?.string)
                }
            }
            return .question(ChatQuestion(prompt: prompt, options: options))
        }
    }

    private func genericToolUseKind(
        toolName: String,
        input: TranscriptJSONValue?
    ) -> ChatMessageKind {
        var summary = toolName
        if let input {
            for key in Self.summaryArgumentKeys {
                if let value = input[key]?.string,
                    !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    summary = "\(toolName) \(budget.summaryArgument(value))"
                    break
                }
            }
        }
        let detail = input.map { budget.inputDetail($0.compactJSONString()) }
        return .toolUse(
            ChatToolUse(
                toolName: toolName,
                summary: summary,
                inputDetail: detail,
                referencedPaths: referencedPaths.referencedPaths(in: input)
            )
        )
    }

    private func blockID(lineID: String, emitted: Int) -> String {
        emitted == 0 ? lineID : "\(lineID)#\(emitted)"
    }
}
