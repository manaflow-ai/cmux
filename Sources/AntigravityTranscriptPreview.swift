import Foundation

enum AntigravityTranscriptPreview {
    private static let maxPreviewBytes = 16 * 1024 * 1024
    private static let maxTurnTextCharacters = 40_000

    static func load(from url: URL, sessionId: String, limit: Int) throws -> [SessionTranscriptTurn] {
        guard limit > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionTranscriptLoadError.missingFile
        }

        var turns: [SessionTranscriptTurn] = []
        var lineIndex = 0
        var didHitTurnLimit = false

        SessionIndexStore.forEachJSONLine(url: url, maxBytes: maxPreviewBytes) { object in
            defer { lineIndex += 1 }
            if Task.isCancelled { return true }
            if url.lastPathComponent == "history.jsonl",
               historySessionID(in: object) != sessionId {
                return false
            }
            guard let turn = transcriptTurn(in: object, id: lineIndex) else {
                return false
            }
            guard turns.count < limit else {
                didHitTurnLimit = true
                return true
            }
            turns.append(turn)
            return false
        }

        if didHitTurnLimit {
            appendTurnLimitMarker(to: &turns, id: lineIndex)
        }
        return coalesce(turns)
    }

    static func userRequestText(from content: String) -> String? {
        let startTag = "<USER_REQUEST>"
        let endTag = "</USER_REQUEST>"
        guard let startRange = content.range(of: startTag),
              let endRange = content.range(of: endTag, range: startRange.upperBound..<content.endIndex) else {
            return nil
        }
        return trimmedNonEmpty(String(content[startRange.upperBound..<endRange.lowerBound]))
    }

    private static func transcriptTurn(
        in object: [String: Any],
        id: Int
    ) -> SessionTranscriptTurn? {
        if let historyContent = object["display"] ?? object["prompt"] ?? object["text"] ?? object["message"],
           historySessionID(in: object) != nil {
            guard let text = normalizedText(from: historyContent, role: .user) else {
                return nil
            }
            return SessionTranscriptTurn(id: id, role: .user, text: text)
        }

        let source = object["source"] as? String
        let type = object["type"] as? String
        switch (source, type) {
        case ("USER_EXPLICIT", "USER_INPUT"):
            guard let content = object["content"] as? String,
                  let text = normalizedText(
                      from: userRequestText(from: content) ?? content,
                      role: .user
                  ) else {
                return nil
            }
            return SessionTranscriptTurn(id: id, role: .user, text: text)
        case ("MODEL", "PLANNER_RESPONSE"):
            guard let text = normalizedText(from: object["content"], role: .assistant) else {
                return nil
            }
            return SessionTranscriptTurn(id: id, role: .assistant, text: text)
        case ("MODEL", "ERROR_MESSAGE"):
            guard let text = normalizedText(from: object["content"], role: .event) else {
                return nil
            }
            return SessionTranscriptTurn(id: id, role: .event, text: text)
        default:
            return nil
        }
    }

    private static func historySessionID(in object: [String: Any]) -> String? {
        for key in ["conversationId", "conversation_id", "sessionId", "session_id", "id"] {
            guard let value = object[key] as? String else { continue }
            if let trimmed = trimmedNonEmpty(value) {
                return trimmed
            }
        }
        return nil
    }

    private static func normalizedText(
        from value: Any?,
        role: SessionTranscriptRole
    ) -> String? {
        let text = textFragments(from: value)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return truncatedText(text, role: role)
    }

    private static func textFragments(from value: Any?) -> [String] {
        guard let value else { return [] }
        if let string = value as? String {
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap { textFragments(from: $0) }
        }
        guard let object = value as? [String: Any] else {
            return []
        }

        switch object["type"] as? String {
        case "text", "input_text", "output_text":
            if let text = object["text"] as? String ?? object["content"] as? String {
                return [text]
            }
        case "tool_use", "tool-call", "tool_call", "function_call":
            return toolCallFragments(from: object)
        case "tool_result", "tool-result", "function_call_output":
            let fragments = textFragments(from: object["content"] ?? object["output"] ?? object["result"])
            if !fragments.isEmpty {
                return fragments
            }
        default:
            break
        }

        for key in ["text", "content", "output", "result", "message"] {
            let fragments = textFragments(from: object[key])
            if !fragments.isEmpty {
                return fragments
            }
        }
        return []
    }

    private static func toolCallFragments(from object: [String: Any]) -> [String] {
        var parts: [String] = []
        if let name = object["name"] as? String, !name.isEmpty {
            parts.append(name)
        }
        if let input = object["input"] ?? object["arguments"],
           let rendered = renderedJSON(input) {
            parts.append(rendered)
        }
        return parts
    }

    private static func renderedJSON(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func coalesce(_ turns: [SessionTranscriptTurn]) -> [SessionTranscriptTurn] {
        var output: [SessionTranscriptTurn] = []
        for turn in turns {
            if let last = output.last, last.role == turn.role {
                output[output.count - 1] = SessionTranscriptTurn(
                    id: last.id,
                    role: last.role,
                    text: last.text + "\n\n" + turn.text
                )
            } else {
                output.append(turn)
            }
        }
        return output.enumerated().map { offset, turn in
            SessionTranscriptTurn(id: offset, role: turn.role, text: turn.text)
        }
    }

    private static func truncatedText(_ text: String, role: SessionTranscriptRole) -> String {
        let limit = role == .tool ? 12_000 : maxTurnTextCharacters
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        let marker = String(localized: "sessionIndex.preview.truncated", defaultValue: "Preview truncated")
        return String(text[..<index]) + "\n\n" + marker
    }

    private static func appendTurnLimitMarker(to turns: inout [SessionTranscriptTurn], id: Int) {
        turns.append(
            SessionTranscriptTurn(
                id: id,
                role: .event,
                text: String(localized: "sessionIndex.preview.truncated", defaultValue: "Preview truncated")
            )
        )
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
