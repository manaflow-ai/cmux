import Foundation

enum SessionTranscriptLoadError: Error {
    case missingFile
    case databaseError(String)
}

struct RovoDevTranscriptPreviewTurn: Equatable, Sendable {
    let role: String
    let text: String
}

enum RovoDevTranscriptPreview {
    private static let maxJSONBytes = 8 * 1024 * 1024

    static func load(from url: URL, limit: Int) throws -> [RovoDevTranscriptPreviewTurn]? {
        guard limit > 0 else { return [] }
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maxJSONBytes {
            return nil
        }

        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseContextObject(object, limit: limit)
    }

    private static func parseContextObject(
        _ object: [String: Any],
        limit: Int
    ) -> [RovoDevTranscriptPreviewTurn]? {
        for key in ["messages", "conversation", "turns", "entries"] {
            if let turns = parseMessages(object[key], limit: limit) {
                return turns
            }
        }
        return nil
    }

    private static func parseMessages(_ value: Any?, limit: Int) -> [RovoDevTranscriptPreviewTurn]? {
        guard let messages = value as? [Any] else { return nil }

        var turns: [RovoDevTranscriptPreviewTurn] = []
        var didHitLimit = false
        for message in messages {
            guard turns.count < limit else {
                didHitLimit = true
                break
            }
            guard let object = message as? [String: Any],
                  let turn = parseMessageObject(object) else {
                continue
            }
            turns.append(turn)
        }
        if didHitLimit {
            turns.append(RovoDevTranscriptPreviewTurn(
                role: "event",
                text: String(localized: "sessionIndex.preview.truncated", defaultValue: "Preview truncated")
            ))
        }
        guard !turns.isEmpty else {
            return nil
        }
        return turns
    }

    private static func parseMessageObject(_ object: [String: Any]) -> RovoDevTranscriptPreviewTurn? {
        for candidate in candidateMessages(from: object) {
            if let turn = parseCandidate(candidate) {
                return turn
            }
        }
        return nil
    }

    private static func candidateMessages(from object: [String: Any]) -> [[String: Any]] {
        var candidates = [object]
        for key in ["payload", "message", "data"] {
            if let nested = object[key] as? [String: Any] {
                candidates.append(nested)
            }
        }
        return candidates
    }

    private static func parseCandidate(_ object: [String: Any]) -> RovoDevTranscriptPreviewTurn? {
        guard let role = normalizedRole(
            object["role"] as? String
                ?? object["speaker"] as? String
                ?? object["sender"] as? String
                ?? object["author"] as? String
                ?? object["type"] as? String
        ) else {
            return nil
        }

        let content = object["content"]
            ?? object["text"]
            ?? object["message"]
            ?? object["parts"]
            ?? object["blocks"]
            ?? object["output"]
            ?? object["result"]
        let text = textFragments(from: content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return RovoDevTranscriptPreviewTurn(role: role, text: text)
    }

    private static func normalizedRole(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "user", "human":
            return "user"
        case "assistant", "ai", "agent":
            return "assistant"
        case "system", "developer":
            return "system"
        case "tool", "tool_use", "tool_result", "function_call", "function_call_output":
            return "tool"
        default:
            return "event"
        }
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
            if let text = object["text"] as? String {
                return [text]
            }
        case "tool_use", "function_call":
            return toolCallFragments(from: object)
        case "tool_result", "function_call_output":
            let fragments = textFragments(from: object["content"] ?? object["output"] ?? object["result"])
            if !fragments.isEmpty {
                return fragments
            }
        default:
            break
        }

        for key in ["text", "content", "parts", "blocks", "output", "result", "message"] {
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
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
