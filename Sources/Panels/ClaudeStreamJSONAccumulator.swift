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
