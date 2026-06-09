import Foundation

/// Parses Claude Code transcripts (`~/.claude/projects/<dir>/<uuid>.jsonl`).
///
/// Each line is one JSON object with a top-level `type`. Conversation turns are
/// `user`, `assistant`, and `system`; `summary`, `queue-operation`,
/// `attachment`, `mode`, `last-prompt`, and any other type are skipped. The
/// turn's content lives in `message.content`, which is either a plain string or
/// an array of typed blocks (`text`, `tool_use`, `tool_result`, `thinking`,
/// `image`). A `tool_result` block appears inside a `user` line and is emitted
/// as a ``MessageRole/toolResult`` message correlated by `tool_use_id`; the
/// call and result are kept as separate messages, not merged.
///
/// ```swift
/// let conversation = ClaudeCodeTranscriptParser().parse(lines: lines)
/// ```
public struct ClaudeCodeTranscriptParser: AgentTranscriptParsing {
    /// Always ``AgentKind/claudeCode``.
    public let agentKind: AgentKind = .claudeCode

    /// Shared per-line JSON/timestamp decoding.
    private let decoder = TranscriptLineDecoder()

    /// Creates a Claude Code transcript parser.
    public init() {}

    /// Parses Claude Code transcript lines into a conversation.
    ///
    /// - Parameter lines: The `.jsonl` transcript lines.
    /// - Returns: The parsed conversation. Unknown line types are skipped.
    public func parse(lines: [String]) -> Conversation {
        var messages: [Message] = []
        var sessionId = ""
        var index = 0

        for line in lines {
            guard let object = decoder.object(from: line) else { continue }
            if sessionId.isEmpty, let id = object["sessionId"] as? String {
                sessionId = id
            }
            guard let type = object["type"] as? String else { continue }
            let timestamp = decoder.date(from: object["timestamp"])

            switch type {
            case "user":
                appendUserMessages(from: object, timestamp: timestamp, index: &index, into: &messages)
            case "assistant":
                appendAssistantMessages(from: object, timestamp: timestamp, index: &index, into: &messages)
            default:
                // summary, system, queue-operation, attachment, mode,
                // last-prompt, and any future type are not conversation turns.
                continue
            }
        }

        return Conversation(
            id: sessionId,
            agentKind: .claudeCode,
            sessionId: sessionId,
            messages: messages,
            seq: UInt64(messages.count)
        )
    }

    /// Appends the user-line content as one or more messages. A user line is
    /// either a plain prompt or a carrier for one or more `tool_result` blocks.
    private func appendUserMessages(
        from object: [String: Any],
        timestamp: Date?,
        index: inout Int,
        into messages: inout [Message]
    ) {
        guard let message = object["message"] as? [String: Any] else { return }
        let content = message["content"]

        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            messages.append(makeMessage(role: .user, blocks: [.text(text)], timestamp: timestamp, index: &index))
            return
        }

        guard let blockArray = content as? [[String: Any]] else { return }
        var promptBlocks: [ContentBlock] = []
        for raw in blockArray {
            guard let blockType = raw["type"] as? String else { continue }
            switch blockType {
            case "tool_result":
                // Flush any accumulated prompt text before the result so order
                // is preserved, then emit the result as its own message.
                flush(&promptBlocks, role: .user, timestamp: timestamp, index: &index, into: &messages)
                if let result = toolResult(from: raw) {
                    messages.append(
                        makeMessage(
                            role: .toolResult,
                            blocks: [.toolResult(result)],
                            timestamp: timestamp,
                            toolCallID: result.toolUseID,
                            index: &index
                        )
                    )
                }
            case "text":
                if let text = raw["text"] as? String { promptBlocks.append(.text(text)) }
            case "image":
                if let image = imageRef(from: raw) { promptBlocks.append(.image(image)) }
            default:
                continue
            }
        }
        flush(&promptBlocks, role: .user, timestamp: timestamp, index: &index, into: &messages)
    }

    /// Appends the assistant-line content. Reasoning is split into its own
    /// ``MessageRole/reasoning`` message so the UI can present it distinctly.
    private func appendAssistantMessages(
        from object: [String: Any],
        timestamp: Date?,
        index: inout Int,
        into messages: inout [Message]
    ) {
        guard let message = object["message"] as? [String: Any],
              let blockArray = message["content"] as? [[String: Any]] else { return }

        var assistantBlocks: [ContentBlock] = []
        for raw in blockArray {
            guard let blockType = raw["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let text = raw["text"] as? String, !text.isEmpty {
                    assistantBlocks.append(.text(text))
                }
            case "tool_use":
                if let use = toolUse(from: raw) { assistantBlocks.append(.toolUse(use)) }
            case "thinking":
                let thinking = (raw["thinking"] as? String) ?? ""
                guard !thinking.isEmpty else { continue }
                // Flush assistant blocks first so reasoning keeps its position.
                flush(&assistantBlocks, role: .assistant, timestamp: timestamp, index: &index, into: &messages)
                messages.append(
                    makeMessage(role: .reasoning, blocks: [.reasoning(thinking)], timestamp: timestamp, index: &index)
                )
            case "image":
                if let image = imageRef(from: raw) { assistantBlocks.append(.image(image)) }
            default:
                continue
            }
        }
        flush(&assistantBlocks, role: .assistant, timestamp: timestamp, index: &index, into: &messages)
    }

    /// Builds a ``ToolUse`` from a Claude `tool_use` block.
    private func toolUse(from raw: [String: Any]) -> ToolUse? {
        guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
        let input = raw["input"]
        let inputJSON = decoder.jsonString(from: input) ?? "{}"
        return ToolUse(id: id, name: name, inputJSON: inputJSON, inputSummary: summary(forInput: input))
    }

    /// Builds a ``ToolResult`` from a Claude `tool_result` block. Its `content`
    /// is either a string or an array of inner blocks (`text`, `image`).
    private func toolResult(from raw: [String: Any]) -> ToolResult? {
        guard let toolUseID = raw["tool_use_id"] as? String else { return nil }
        let isError = (raw["is_error"] as? Bool) ?? false
        let content = raw["content"]
        var blocks: [ContentBlock] = []
        if let text = content as? String {
            blocks.append(.text(text))
        } else if let innerArray = content as? [[String: Any]] {
            for inner in innerArray {
                switch inner["type"] as? String {
                case "text":
                    if let text = inner["text"] as? String { blocks.append(.text(text)) }
                case "image":
                    if let image = imageRef(from: inner) { blocks.append(.image(image)) }
                default:
                    continue
                }
            }
        }
        return ToolResult(toolUseID: toolUseID, blocks: blocks, isError: isError)
    }

    /// Builds an ``ImageRef`` from a Claude `image` block. The base64 payload is
    /// referenced (by its byte count and media type) rather than inlined.
    private func imageRef(from raw: [String: Any]) -> ImageRef? {
        let source = raw["source"] as? [String: Any]
        let mediaType = source?["media_type"] as? String
        let data = source?["data"] as? String
        let byteCount = data.map { $0.utf8.count }
        let id = (source?["file_id"] as? String) ?? UUID().uuidString
        return ImageRef(id: id, mediaType: mediaType, byteCount: byteCount)
    }

    /// Emits the accumulated blocks as one message (if any) and clears them.
    private func flush(
        _ blocks: inout [ContentBlock],
        role: MessageRole,
        timestamp: Date?,
        index: inout Int,
        into messages: inout [Message]
    ) {
        guard !blocks.isEmpty else { return }
        messages.append(makeMessage(role: role, blocks: blocks, timestamp: timestamp, index: &index))
        blocks = []
    }

    /// Builds a message with a stable sequential id and advances the counter.
    private func makeMessage(
        role: MessageRole,
        blocks: [ContentBlock],
        timestamp: Date?,
        toolCallID: String? = nil,
        index: inout Int
    ) -> Message {
        defer { index += 1 }
        return Message(
            id: "claude-\(index)",
            role: role,
            blocks: blocks,
            timestamp: timestamp,
            toolCallID: toolCallID
        )
    }

    /// A short one-line summary for a tool input: prefers a `command` or
    /// `file_path` field, else the first scalar value.
    private func summary(forInput input: Any?) -> String? {
        guard let dict = input as? [String: Any] else { return nil }
        for key in ["command", "file_path", "path", "pattern", "query", "url"] {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
