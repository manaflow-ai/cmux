import Foundation

enum SessionTranscriptLoadError: Error {
    case missingFile
    case databaseError(String)
    case incompleteSource
}

struct RovoDevTranscriptPreviewTurn: Equatable, Sendable {
    let role: String
    let text: String
}

enum RovoDevTranscriptPreview {
    private static let maxJSONBytes = 8 * 1024 * 1024

    static func load(
        from url: URL,
        limit: Int,
        latest: Bool = false,
        preservingOpeningUser: Bool = false,
        dialogueOnly: Bool = false,
        expectedStorageGeneration: AgentConversationStorageGeneration? = nil
    ) throws -> [RovoDevTranscriptPreviewTurn]? {
        guard limit > 0 else { return [] }
        guard let data = try boundedJSONData(
            from: url,
            expectedStorageGeneration: expectedStorageGeneration
        ) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseContextObject(
            object,
            limit: limit,
            latest: latest,
            preservingOpeningUser: preservingOpeningUser,
            dialogueOnly: dialogueOnly
        )
    }

    private static func boundedJSONData(
        from url: URL,
        expectedStorageGeneration: AgentConversationStorageGeneration?
    ) throws -> Data? {
        guard url.isFileURL else { return nil }
        guard let snapshot = AgentConversationStorageGeneration.openRegularFile(
            at: url,
            matching: expectedStorageGeneration
        ),
        snapshot.endOffset <= UInt64(maxJSONBytes) else {
            return nil
        }
        let handle = snapshot.handle
        defer { try? handle.close() }
        let expectedByteCount = Int(snapshot.endOffset)
        var data = Data()
        data.reserveCapacity(expectedByteCount)
        while data.count < expectedByteCount {
            let remaining = expectedByteCount - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
                  !chunk.isEmpty else {
                return nil
            }
            data.append(chunk)
        }
        return data.count == expectedByteCount ? data : nil
    }

    private static func parseContextObject(
        _ object: [String: Any],
        limit: Int,
        latest: Bool,
        preservingOpeningUser: Bool,
        dialogueOnly: Bool
    ) -> [RovoDevTranscriptPreviewTurn]? {
        for key in ["message_history", "messages", "conversation", "turns", "entries"] {
            if let turns = parseMessages(
                object[key],
                limit: limit,
                latest: latest,
                preservingOpeningUser: preservingOpeningUser,
                dialogueOnly: dialogueOnly
            ) {
                return turns
            }
        }
        return nil
    }

    private static func parseMessages(
        _ value: Any?,
        limit: Int,
        latest: Bool,
        preservingOpeningUser: Bool,
        dialogueOnly: Bool
    ) -> [RovoDevTranscriptPreviewTurn]? {
        guard let messages = value as? [Any] else { return nil }

        var turns: [RovoDevTranscriptPreviewTurn] = []
        var openingUser: RovoDevTranscriptPreviewTurn?
        var replacementIndex = 0
        var didHitLimit = false
        for message in messages {
            guard latest || turns.count < limit else {
                didHitLimit = true
                break
            }
            guard let object = message as? [String: Any] else {
                continue
            }
            let messageTurns = parseMessageObject(
                object,
                dialogueOnly: dialogueOnly
            )
            for turn in messageTurns {
                guard latest || turns.count < limit else {
                    didHitLimit = true
                    break
                }
                if openingUser == nil, turn.role == "user" {
                    openingUser = turn
                }
                guard !dialogueOnly || turn.role == "user" || turn.role == "assistant" else {
                    continue
                }
                if turns.count < limit {
                    turns.append(turn)
                } else {
                    turns[replacementIndex] = turn
                    replacementIndex = (replacementIndex + 1) % limit
                }
            }
        }
        if latest {
            let ordered: [RovoDevTranscriptPreviewTurn]
            if turns.count < limit || replacementIndex == 0 {
                ordered = turns
            } else {
                ordered = Array(turns[replacementIndex...]) + Array(turns[..<replacementIndex])
            }
            guard preservingOpeningUser,
                  let openingUser,
                  !ordered.contains(openingUser) else {
                return ordered.isEmpty ? nil : ordered
            }
            return [openingUser] + Array(ordered.suffix(max(0, limit - 1)))
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

    private static func parseMessageObject(
        _ object: [String: Any],
        dialogueOnly: Bool
    ) -> [RovoDevTranscriptPreviewTurn] {
        if object["parts"] != nil {
            return parseRovoDevParts(object, dialogueOnly: dialogueOnly)
        }

        for candidate in candidateMessages(from: object) {
            if let turn = parseCandidate(candidate, dialogueOnly: dialogueOnly) {
                return [turn]
            }
        }
        return []
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

    private static func parseCandidate(
        _ object: [String: Any],
        dialogueOnly: Bool
    ) -> RovoDevTranscriptPreviewTurn? {
        guard let role = normalizedRole(
            object["role"] as? String
                ?? object["kind"] as? String
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
        let text = textFragments(from: content, dialogueOnly: dialogueOnly)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return RovoDevTranscriptPreviewTurn(role: role, text: text)
    }

    private static func normalizedRole(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "user", "human", "request":
            return "user"
        case "assistant", "ai", "agent", "response":
            return "assistant"
        case "system", "developer":
            return "system"
        case "tool", "tool_use", "tool_result", "function_call", "function_call_output":
            return "tool"
        default:
            return "event"
        }
    }

    private static func parseRovoDevParts(
        _ object: [String: Any],
        dialogueOnly: Bool
    ) -> [RovoDevTranscriptPreviewTurn] {
        guard let parts = object["parts"] as? [Any] else { return [] }
        let messageRole = normalizedRole(
            object["role"] as? String
                ?? object["kind"] as? String
                ?? object["type"] as? String
        ) ?? "event"

        return parts.compactMap { part in
            guard let partObject = part as? [String: Any] else {
                let text = textFragments(from: part, dialogueOnly: dialogueOnly)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                guard !text.isEmpty else { return nil }
                return RovoDevTranscriptPreviewTurn(role: messageRole, text: text)
            }
            return parseRovoDevPart(
                partObject,
                messageRole: messageRole,
                dialogueOnly: dialogueOnly
            )
        }
    }

    private static func parseRovoDevPart(
        _ object: [String: Any],
        messageRole: String,
        dialogueOnly: Bool
    ) -> RovoDevTranscriptPreviewTurn? {
        guard !dialogueOnly || !isNonDialogueContentObject(object) else {
            return nil
        }
        let kind = (object["part_kind"] as? String ?? object["type"] as? String)?.lowercased()
        let role: String
        let fragments: [String]

        switch kind {
        case "text", "user-prompt", "retry-prompt":
            role = messageRole == "event" && kind != "text" ? "user" : messageRole
            fragments = textFragments(
                from: object["content"] ?? object["text"],
                dialogueOnly: dialogueOnly
            )
        case "system-prompt":
            return nil
        case "tool-call", "tool_call", "tool-use", "tool_use", "function_call":
            role = "tool"
            fragments = toolCallFragments(from: object)
        case "tool-result", "tool_result", "tool-return", "tool_return", "function_call_output":
            role = "tool"
            let primary = object["content"] ?? object["output"] ?? object["result"]
            fragments = textFragments(from: primary, dialogueOnly: dialogueOnly)
        default:
            role = messageRole
            fragments = textFragments(
                from: object["content"]
                    ?? object["text"]
                    ?? object["message"]
                    ?? object["output"]
                    ?? object["result"],
                dialogueOnly: dialogueOnly
            )
        }

        let text = fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return RovoDevTranscriptPreviewTurn(role: role, text: text)
    }

    private static func textFragments(
        from value: Any?,
        dialogueOnly: Bool
    ) -> [String] {
        guard let value else { return [] }
        if let string = value as? String {
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap {
                textFragments(from: $0, dialogueOnly: dialogueOnly)
            }
        }
        guard let object = value as? [String: Any] else {
            return []
        }
        guard !dialogueOnly || !isNonDialogueContentObject(object) else {
            return []
        }

        switch object["type"] as? String {
        case "text", "input_text", "output_text":
            if let text = object["text"] as? String ?? object["content"] as? String {
                return [text]
            }
        case "tool_use", "tool-call", "tool_call", "function_call":
            return toolCallFragments(from: object)
        case "tool_result", "tool-result", "tool_return", "function_call_output":
            let fragments = textFragments(
                from: object["content"] ?? object["output"] ?? object["result"],
                dialogueOnly: dialogueOnly
            )
            if !fragments.isEmpty {
                return fragments
            }
        default:
            break
        }

        switch object["part_kind"] as? String {
        case "text", "user-prompt", "retry-prompt":
            if let text = object["content"] as? String ?? object["text"] as? String {
                return [text]
            }
        case "system-prompt":
            return []
        case "tool-use", "tool_use", "tool-call", "tool_call":
            return toolCallFragments(from: object)
        case "tool-result", "tool_result", "tool-return", "tool_return":
            let fragments = textFragments(
                from: object["content"] ?? object["output"] ?? object["result"],
                dialogueOnly: dialogueOnly
            )
            if !fragments.isEmpty {
                return fragments
            }
        default:
            break
        }

        for key in ["text", "content", "parts", "blocks", "output", "result", "message"] {
            let fragments = textFragments(
                from: object[key],
                dialogueOnly: dialogueOnly
            )
            if !fragments.isEmpty {
                return fragments
            }
        }
        return []
    }

    /// Dialogue-only transfers keep natural-language user and assistant text,
    /// even when Rovo nests content blocks inside a role-based message. A
    /// nested block's own type or role takes precedence over its parent role.
    private static func isNonDialogueContentObject(_ object: [String: Any]) -> Bool {
        for key in ["role", "speaker", "sender", "author"] {
            guard let rawRole = object[key] as? String,
                  let role = normalizedRole(rawRole) else {
                continue
            }
            if role != "user", role != "assistant" {
                return true
            }
        }

        for key in ["type", "part_kind", "kind"] {
            guard let rawMarker = object[key] as? String else { continue }
            let marker = rawMarker
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            if marker == "system"
                || marker == "developer"
                || marker == "system-prompt"
                || marker == "tool"
                || marker.hasPrefix("tool-")
                || marker == "function-call"
                || marker.hasPrefix("function-call-")
                || marker == "function-result"
                || marker.hasPrefix("function-result-")
                || marker == "function-output"
                || marker.hasPrefix("function-output-") {
                return true
            }
        }
        return false
    }

    private static func toolCallFragments(from object: [String: Any]) -> [String] {
        var parts: [String] = []
        let name = trimmedToolName(object["name"] as? String)
        let toolName = trimmedToolName(object["tool_name"] as? String)
        if isUnknownToolName(name) || isUnknownToolName(toolName) {
            return []
        }
        if let name {
            parts.append(name)
        }
        if let toolName, parts.isEmpty {
            parts.append(toolName)
        }
        if let input = object["input"] ?? object["arguments"] ?? object["tool_input"],
           !isEmptyJSONContainer(input),
           let rendered = renderedJSON(input) {
            parts.append(rendered)
        }
        return parts
    }

    private static func trimmedToolName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isUnknownToolName(_ name: String?) -> Bool {
        name?.lowercased() == "unknown"
    }

    private static func isEmptyJSONContainer(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object.isEmpty
        }
        if let array = value as? [Any] {
            return array.isEmpty
        }
        return false
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
