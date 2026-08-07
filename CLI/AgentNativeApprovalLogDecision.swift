import Foundation

/// A native post-policy approval decision correlated to one tool call.
enum AgentNativeApprovalLogDecision: Equatable, Sendable {
    /// The agent will show its own approval prompt.
    case approvalRequested(toolCallId: String)
    /// The agent's policy allowed the tool without prompting.
    case autoApproved(toolCallId: String)

    private static let requestingMarker =
        "Shell permissions: requesting shell approval"
    private static let autoApprovedMarker =
        "Shell permissions: auto-approved shell command"

    /// Classifies one Cursor native-policy log record.
    ///
    /// A decision is returned only when the record contains a non-empty tool
    /// call identifier and, when supplied, it exactly matches the expected id.
    static func classify(
        line: String,
        expectedToolCallId: String? = nil
    ) -> Self? {
        let isApprovalRequest: Bool
        let toolCallId: String?
        if let dictionary = decodedObject(in: line) {
            let message = ["msg", "message"].compactMap {
                dictionary[$0] as? String
            }.first
            if message == requestingMarker {
                isApprovalRequest = true
            } else if message == autoApprovedMarker {
                isApprovalRequest = false
            } else {
                return nil
            }
            toolCallId = dictionary["toolCallId"] as? String
        } else {
            if containsPrefixedDecisionMessage(requestingMarker, in: line) {
                isApprovalRequest = true
            } else if containsPrefixedDecisionMessage(autoApprovedMarker, in: line) {
                isApprovalRequest = false
            } else {
                return nil
            }
            toolCallId = jsonStringField("toolCallId", in: line)
        }

        guard let toolCallId, !toolCallId.isEmpty else { return nil }
        if let expectedToolCallId, toolCallId != expectedToolCallId {
            return nil
        }
        return isApprovalRequest
            ? .approvalRequested(toolCallId: toolCallId)
            : .autoApproved(toolCallId: toolCallId)
    }

    private static func decodedObject(in line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func containsPrefixedDecisionMessage(
        _ expected: String,
        in line: String
    ) -> Bool {
        // Older Cursor loggers prefix a timestamp and append structured fields.
        // Requiring the object immediately after the marker prevents a command
        // string from forging a native policy decision.
        guard let range = line.range(of: expected) else { return false }
        return line[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("{")
    }

    private static func jsonStringField(
        _ key: String,
        in line: String
    ) -> String? {
        let marker = "\"\(key)\""
        guard let keyRange = line.range(of: marker) else { return nil }
        var cursor = keyRange.upperBound
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex, line[cursor] == ":" else { return nil }
        cursor = line.index(after: cursor)
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex, line[cursor] == "\"" else { return nil }
        cursor = line.index(after: cursor)

        var value = ""
        var escaped = false
        while cursor < line.endIndex {
            let character = line[cursor]
            cursor = line.index(after: cursor)
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return value.isEmpty ? nil : value
            } else {
                value.append(character)
            }
        }
        return nil
    }
}
