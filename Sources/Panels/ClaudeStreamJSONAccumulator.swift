import Foundation

struct ClaudeStreamJSONAccumulator {
    private static let maxTrackedMessages = 16

    private var emittedCharacterCountByMessageID: [String: Int] = [:]
    private var messageIDOrder: [String] = []
    private var currentMessageID: String?
    private var pendingDeltaCharacterCount = 0
    private var emittedAnyAssistantText = false

    var retainedTextCharacterCountForTesting: Int {
        0
    }

    mutating func consumeLine(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // `claude --include-partial-messages` wraps every streaming SSE event in a
        // {"type":"stream_event","event":{…}} envelope, then emits one aggregate
        // top-level `assistant` message carrying the full turn text. Unwrap the
        // envelope and surface only the streamed signals (message id + text
        // deltas). Nested terminal events (message_stop / message_delta) are
        // intentionally ignored: the aggregate `assistant` message is the de-dup
        // anchor and the top-level `result` is the real turn terminator, so
        // resetting on a nested stop would make the aggregate re-emit the turn.
        if object["type"] as? String == "stream_event" {
            guard let event = object["event"] as? [String: Any] else { return [] }
            return assistantSignal(from: event) ?? []
        }

        if let signal = assistantSignal(from: object) {
            return signal
        }

        if !emittedAnyAssistantText,
           object["type"] as? String == "result",
           let result = object["result"] as? String,
           !result.isEmpty {
            emittedAnyAssistantText = true
            resetTurnTracking()
            return [result]
        }

        if Self.completesAssistantTurn(from: object) {
            resetTurnTracking()
        }
        return []
    }

    /// Streamed assistant text from a single event — either a top-level
    /// `assistant` / `content_block_delta` line or the inner event of a
    /// `stream_event` envelope. `nil` means "no assistant signal", so the caller
    /// can apply its top-level-only `result` / turn-completion handling.
    private mutating func assistantSignal(from object: [String: Any]) -> [String]? {
        if let messageID = assistantMessageID(fromMessageStart: object) {
            beginAssistantMessage(messageID)
            return []
        }
        if let text = contentBlockDeltaText(from: object) {
            guard !text.isEmpty else { return [] }
            emittedAnyAssistantText = true
            return recordIncrementalDelta(text)
        }
        if let tail = aggregateAssistantTail(from: object) {
            guard !tail.isEmpty else { return [] }
            emittedAnyAssistantText = true
            return [tail]
        }
        return nil
    }

    private mutating func beginAssistantMessage(_ messageID: String) {
        rememberMessageID(messageID)
        currentMessageID = messageID
        pendingDeltaCharacterCount = 0
    }

    /// Accounts a streamed text delta under the current message (or the
    /// un-anchored fallback counter when no message_start has been seen) and
    /// returns it for emission.
    private mutating func recordIncrementalDelta(_ delta: String) -> [String] {
        if let currentMessageID {
            rememberMessageID(currentMessageID)
            emittedCharacterCountByMessageID[currentMessageID, default: 0] += delta.count
        } else {
            pendingDeltaCharacterCount += delta.count
        }
        return [delta]
    }

    static func completesAssistantTurn(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }

        return completesAssistantTurn(type: type)
    }

    private static func completesAssistantTurn(from object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String else { return false }
        return completesAssistantTurn(type: type)
    }

    private static func completesAssistantTurn(type: String) -> Bool {
        switch type {
        case "result", "message_stop", "done":
            return true
        default:
            return false
        }
    }

    private func assistantMessageID(fromMessageStart object: [String: Any]) -> String? {
        guard object["type"] as? String == "message_start",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let messageID = message["id"] as? String,
              !messageID.isEmpty else {
            return nil
        }
        return messageID
    }

    /// Text of a streaming `content_block_delta` event, or nil if `object` is not
    /// one. Pure — accounting happens in `recordIncrementalDelta`.
    private func contentBlockDeltaText(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "content_block_delta",
              let delta = object["delta"] as? [String: Any],
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    /// Reconciles an aggregate top-level `assistant` message against text already
    /// streamed for the same message id, returning only the not-yet-emitted tail
    /// (empty when the streamed deltas already covered it). Returns nil if
    /// `object` is not an assistant message. Always updates the de-dup checkpoint
    /// and clears the un-anchored delta counter: the tail belongs to `messageID`,
    /// so it must not leak into the next message's accounting.
    private mutating func aggregateAssistantTail(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "assistant" else {
            return nil
        }
        let message = (object["message"] as? [String: Any]) ?? object
        let fullText = Self.contentText(from: message["content"])
        guard !fullText.isEmpty else { return nil }

        let messageID = (message["id"] as? String) ?? "assistant"
        rememberMessageID(messageID)
        let previousCharacterCount = emittedCharacterCountByMessageID[messageID] ??
            min(pendingDeltaCharacterCount, fullText.count)
        emittedCharacterCountByMessageID[messageID] = fullText.count
        if currentMessageID == messageID {
            currentMessageID = nil
        }
        pendingDeltaCharacterCount = 0
        guard previousCharacterCount > 0, fullText.count >= previousCharacterCount else {
            return fullText
        }
        return String(fullText.dropFirst(previousCharacterCount))
    }

    private mutating func rememberMessageID(_ messageID: String) {
        if !messageIDOrder.contains(messageID) {
            messageIDOrder.append(messageID)
        }
        while messageIDOrder.count > Self.maxTrackedMessages {
            let removed = messageIDOrder.removeFirst()
            emittedCharacterCountByMessageID.removeValue(forKey: removed)
        }
    }

    private mutating func resetTurnTracking() {
        emittedCharacterCountByMessageID.removeAll(keepingCapacity: true)
        messageIDOrder.removeAll(keepingCapacity: true)
        currentMessageID = nil
        pendingDeltaCharacterCount = 0
    }

    private static func contentText(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let part = content as? [String: Any] {
            if let type = part["type"] as? String,
               type != "text" {
                return ""
            }
            return part["text"] as? String ?? ""
        }
        if let parts = content as? [Any] {
            return parts.map(contentText(from:)).joined()
        }
        return ""
    }
}

/// Parses Claude's stream-JSON for *activity* signals — thinking blocks and tool
/// calls — into `provider.activity`-shaped dictionaries the webview already knows
/// how to render (`appendProviderActivityTranscript` → `ToolActivityTurn`). This
/// is the activity counterpart to ``ClaudeStreamJSONAccumulator`` (which extracts
/// assistant text); keeping the two concerns separate mirrors Codex, which feeds
/// the same UI through distinct output and activity sinks.
///
/// A tool call spans three places in the stream: a `content_block_start` of type
/// `tool_use` (carries the id + name), streamed `input_json_delta`s (the
/// arguments, keyed only by block index), and — later, in a separate top-level
/// `user` message — a `tool_result` that finalizes it. The accumulator bridges
/// those with a stable `activityId` (the tool-use id) so the row updates in place.
struct ClaudeActivityAccumulator {
    private struct ToolCall {
        let id: String
        let name: String
        var inputJSON: String
    }

    // input_json_delta carries only the content-block index, so active tool calls
    // are tracked by index until their block stops.
    private var toolCallsByBlockIndex: [Int: ToolCall] = [:]
    // Stable kind/action per tool id so the later tool_result finalizes the same row.
    private var toolKindByID: [String: String] = [:]
    private var toolActionByID: [String: String] = [:]
    private var thinkingBlockIndex: Int?
    private var thinkingActivityID: String?
    private var thinkingCounter = 0

    mutating func consumeLine(_ line: String) -> [[String: Any]] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return [] }
            return consumeStreamEvent(event)
        case "user":
            return consumeToolResults(from: object)
        default:
            return []
        }
    }

    private mutating func consumeStreamEvent(_ event: [String: Any]) -> [[String: Any]] {
        switch event["type"] as? String {
        case "content_block_start":
            return consumeContentBlockStart(event)
        case "content_block_delta":
            consumeInputJSONDelta(event)
            return []
        case "content_block_stop":
            return consumeContentBlockStop(event)
        default:
            return []
        }
    }

    private mutating func consumeContentBlockStart(_ event: [String: Any]) -> [[String: Any]] {
        guard let index = event["index"] as? Int,
              let block = event["content_block"] as? [String: Any] else {
            return []
        }
        switch block["type"] as? String {
        case "thinking":
            thinkingCounter += 1
            let id = "thinking:\(thinkingCounter)"
            thinkingBlockIndex = index
            thinkingActivityID = id
            return [Self.activity(id: id, kind: "other", status: "inProgress", action: Self.thinkingAction(inProgress: true))]
        case "tool_use":
            guard let id = block["id"] as? String,
                  let name = block["name"] as? String else {
                return []
            }
            toolCallsByBlockIndex[index] = ToolCall(id: id, name: name, inputJSON: "")
            let kind = Self.toolKind(name: name)
            let action = Self.toolAction(name: name, summary: nil)
            toolKindByID[id] = kind
            toolActionByID[id] = action
            return [Self.activity(id: id, kind: kind, status: "inProgress", action: action)]
        default:
            return []
        }
    }

    private mutating func consumeInputJSONDelta(_ event: [String: Any]) {
        guard let index = event["index"] as? Int,
              toolCallsByBlockIndex[index] != nil,
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "input_json_delta",
              let partial = delta["partial_json"] as? String else {
            return
        }
        toolCallsByBlockIndex[index]?.inputJSON += partial
    }

    private mutating func consumeContentBlockStop(_ event: [String: Any]) -> [[String: Any]] {
        guard let index = event["index"] as? Int else { return [] }

        if index == thinkingBlockIndex, let id = thinkingActivityID {
            thinkingBlockIndex = nil
            thinkingActivityID = nil
            return [Self.activity(id: id, kind: "other", status: "completed", action: Self.thinkingAction(inProgress: false))]
        }

        guard let call = toolCallsByBlockIndex.removeValue(forKey: index) else {
            return []
        }
        // The tool arguments are complete: refine the label with a summary. Still
        // in progress until the matching tool_result lands.
        let summary = Self.argumentSummary(name: call.name, inputJSON: call.inputJSON)
        let action = Self.toolAction(name: call.name, summary: summary)
        toolActionByID[call.id] = action
        let kind = toolKindByID[call.id] ?? Self.toolKind(name: call.name)
        return [Self.activity(id: call.id, kind: kind, status: "inProgress", action: action)]
    }

    private mutating func consumeToolResults(from object: [String: Any]) -> [[String: Any]] {
        let message = (object["message"] as? [String: Any]) ?? object
        guard let content = message["content"] as? [Any] else { return [] }
        var emissions: [[String: Any]] = []
        for case let part as [String: Any] in content where part["type"] as? String == "tool_result" {
            guard let id = part["tool_use_id"] as? String else { continue }
            let status = ((part["is_error"] as? Bool) ?? false) ? "failed" : "completed"
            let kind = toolKindByID.removeValue(forKey: id) ?? "other"
            let action = toolActionByID.removeValue(forKey: id) ?? Self.toolAction(name: "", summary: nil)
            let preview = Self.resultPreview(part["content"])
            emissions.append(Self.activity(id: id, kind: kind, status: status, action: action, outputDelta: preview))
        }
        return emissions
    }

    private static func activity(
        id: String,
        kind: String,
        status: String,
        action: String,
        outputDelta: String? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "activityId": id,
            "kind": kind,
            "status": status,
            "action": action
        ]
        if let outputDelta, !outputDelta.isEmpty {
            dict["outputDelta"] = outputDelta
        }
        return dict
    }

    private static func thinkingAction(inProgress: Bool) -> String {
        inProgress
            ? String(localized: "agentSession.claude.activity.thinking", defaultValue: "Thinking…")
            : String(localized: "agentSession.claude.activity.thought", defaultValue: "Thought")
    }

    private static func toolKind(name: String) -> String {
        switch name {
        case "Bash", "BashOutput", "KillShell":
            return "command"
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return "fileChange"
        default:
            return "other"
        }
    }

    private static func toolAction(name: String, summary: String?) -> String {
        let label = name.isEmpty
            ? String(localized: "agentSession.claude.activity.tool", defaultValue: "Tool")
            : name
        guard let summary, !summary.isEmpty else { return label }
        return "\(label) · \(summary)"
    }

    private static func argumentSummary(name: String, inputJSON: String) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch name {
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            if let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) {
                return (path as NSString).lastPathComponent
            }
        case "Bash":
            if let command = input["command"] as? String {
                return Self.truncated(command.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "Grep", "Glob":
            if let pattern = input["pattern"] as? String {
                return Self.truncated(pattern)
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return Self.truncated(url)
            }
        case "Task":
            if let description = input["description"] as? String {
                return Self.truncated(description)
            }
        default:
            break
        }
        return nil
    }

    private static func resultPreview(_ content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let parts = content as? [Any] {
            text = parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(4000))
    }

    private static func truncated(_ text: String, limit: Int = 80) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}

