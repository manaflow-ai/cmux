import Foundation

/// Parses Codex transcripts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
///
/// Each line is one JSON object with a top-level `type`. Only `response_item`
/// lines carry conversation content (`session_meta` supplies the session id;
/// `turn_context`, `event_msg`, and `token_count` are dropped). Within a
/// `response_item`, `payload.type` selects the shape:
///
/// - `message` → `{role, content[]}` with `input_text`/`output_text` blocks.
/// - `reasoning` → `{summary, content}` reasoning text.
/// - `function_call` → `{call_id, name, arguments}` (a ``ToolUse``).
/// - `function_call_output` → `{call_id, output}` (a ``ToolResult``).
///
/// `event_msg` `user_message`/`agent_message` lines are intentionally dropped
/// because they duplicate the text already present in the `response_item`
/// `message` lines. Envelope `developer`/`user` messages (`<permissions>`,
/// `<environment_context>`, `# AGENTS.md`, …) are stripped so only real prompts
/// surface.
///
/// ```swift
/// let conversation = CodexTranscriptParser().parse(lines: lines)
/// ```
public struct CodexTranscriptParser: AgentTranscriptParsing {
    /// Always ``AgentKind/codex``.
    public let agentKind: AgentKind = .codex

    /// Shared per-line JSON/timestamp decoding.
    private let decoder = TranscriptLineDecoder()

    /// Creates a Codex transcript parser.
    public init() {}

    /// Parses Codex rollout lines into a conversation.
    ///
    /// - Parameter lines: The rollout `.jsonl` lines.
    /// - Returns: The parsed conversation. `event_msg`/`token_count` noise and
    ///   unknown payload types are skipped.
    public func parse(lines: [String]) -> Conversation {
        var messages: [Message] = []
        var sessionId = ""
        var index = 0

        for line in lines {
            guard let object = decoder.object(from: line) else { continue }
            guard let type = object["type"] as? String else { continue }
            let timestamp = decoder.date(from: object["timestamp"])

            switch type {
            case "session_meta":
                if sessionId.isEmpty,
                   let payload = object["payload"] as? [String: Any],
                   let id = payload["id"] as? String {
                    sessionId = id
                }
            case "response_item":
                guard let payload = object["payload"] as? [String: Any] else { continue }
                appendResponseItem(payload, timestamp: timestamp, index: &index, into: &messages)
            default:
                // turn_context, event_msg (user_message/agent_message/
                // token_count/task_started), and any future type are dropped.
                continue
            }
        }

        return Conversation(
            id: sessionId,
            agentKind: .codex,
            sessionId: sessionId,
            messages: messages,
            seq: UInt64(messages.count)
        )
    }

    /// Dispatches one `response_item` payload by its `type`.
    private func appendResponseItem(
        _ payload: [String: Any],
        timestamp: Date?,
        index: inout Int,
        into messages: inout [Message]
    ) {
        switch payload["type"] as? String {
        case "message":
            appendMessage(payload, timestamp: timestamp, index: &index, into: &messages)
        case "reasoning":
            appendReasoning(payload, timestamp: timestamp, index: &index, into: &messages)
        case "function_call":
            if let use = toolUse(from: payload) {
                messages.append(
                    makeMessage(role: .assistant, blocks: [.toolUse(use)], timestamp: timestamp, index: &index)
                )
            }
        case "function_call_output":
            if let result = toolResult(from: payload) {
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
        default:
            // tool_search_call, web_search_call, and other item types are not
            // part of the rendered conversation.
            return
        }
    }

    /// Appends a `message` payload. `developer` messages map to
    /// ``MessageRole/system``; envelope text is stripped from user prompts.
    private func appendMessage(
        _ payload: [String: Any],
        timestamp: Date?,
        index: inout Int,
        into messages: inout [Message]
    ) {
        guard let rawRole = payload["role"] as? String else { return }

        // `content` is usually an array of typed blocks, but Codex can also
        // store it as a plain string; handle both so a string-form turn is not
        // dropped (the parser also drops the `event_msg` fallback for it).
        let text: String
        if let blocks = payload["content"] as? [[String: Any]] {
            text = joinedText(from: blocks)
        } else if let string = payload["content"] as? String {
            text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return
        }
        guard !text.isEmpty else { return }

        let role: MessageRole
        switch rawRole {
        case "assistant":
            role = .assistant
        case "developer", "system":
            role = .system
        default:
            role = .user
        }

        // Strip envelope/system wrappers (`<permissions>`, `<environment_context>`,
        // `# AGENTS.md`, …) for every role; these are implementation noise, not
        // conversation. A message that is only an envelope is dropped.
        guard let real = realUserMessage(text) else { return }
        messages.append(makeMessage(role: role, blocks: [.text(real)], timestamp: timestamp, index: &index))
    }

    /// Appends a `reasoning` payload built from its `summary` and/or `content`
    /// text blocks. Encrypted-only reasoning (no readable text) is skipped.
    private func appendReasoning(
        _ payload: [String: Any],
        timestamp: Date?,
        index: inout Int,
        into messages: inout [Message]
    ) {
        var pieces: [String] = []
        if let summary = payload["summary"] as? [[String: Any]] {
            let text = joinedText(from: summary)
            if !text.isEmpty { pieces.append(text) }
        }
        if let content = payload["content"] as? [[String: Any]] {
            let text = joinedText(from: content)
            if !text.isEmpty { pieces.append(text) }
        }
        let combined = pieces.joined(separator: "\n\n")
        guard !combined.isEmpty else { return }
        messages.append(makeMessage(role: .reasoning, blocks: [.reasoning(combined)], timestamp: timestamp, index: &index))
    }

    /// Builds a ``ToolUse`` from a Codex `function_call` payload. `arguments` is
    /// already a JSON string in the transcript.
    private func toolUse(from payload: [String: Any]) -> ToolUse? {
        guard let id = payload["call_id"] as? String, let name = payload["name"] as? String else { return nil }
        let arguments = (payload["arguments"] as? String) ?? "{}"
        return ToolUse(id: id, name: name, inputJSON: arguments, inputSummary: summary(forArguments: arguments))
    }

    /// Builds a ``ToolResult`` from a Codex `function_call_output` payload.
    private func toolResult(from payload: [String: Any]) -> ToolResult? {
        guard let id = payload["call_id"] as? String else { return nil }
        let output = stringOutput(from: payload["output"])
        return ToolResult(toolUseID: id, blocks: [.text(output)], isError: false)
    }

    /// Concatenates the `text` fields of `input_text`/`output_text`/`text`
    /// content blocks in order.
    private func joinedText(from content: [[String: Any]]) -> String {
        content.compactMap { block -> String? in
            switch block["type"] as? String {
            case "input_text", "output_text", "text", "summary_text":
                return block["text"] as? String
            default:
                return nil
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Codex `function_call_output.output` is usually a string but can be an
    /// object `{output, metadata}`; this returns the displayable text.
    private func stringOutput(from value: Any?) -> String {
        if let string = value as? String { return string }
        if let dict = value as? [String: Any], let nested = dict["output"] as? String { return nested }
        return decoder.jsonString(from: value) ?? ""
    }

    /// A short one-line summary of a `function_call` arguments JSON string:
    /// prefers a `cmd`/`command`/`path` field.
    private func summary(forArguments arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["cmd", "command", "file_path", "path", "query"] {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let array = dict[key] as? [String], !array.isEmpty { return array.joined(separator: " ") }
        }
        return nil
    }

    /// Returns a real user prompt, or `nil` for envelope/system wrappers
    /// (`<environment_context>`, `<user_instructions>`, `<permissions>`,
    /// `AGENTS.md` preamble). Ported from the app's `realCodexUserMessage`.
    private func realUserMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let envelopePrefixes = [
            "<environment_context",
            "<user_instructions",
            "<permissions",
            "<system",
            "# AGENTS.md",
        ]
        for prefix in envelopePrefixes where trimmed.hasPrefix(prefix) {
            return nil
        }
        return trimmed
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
            id: "codex-\(index)",
            role: role,
            blocks: blocks,
            timestamp: timestamp,
            toolCallID: toolCallID
        )
    }
}
