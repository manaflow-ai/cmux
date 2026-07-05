import Foundation

/// Pure `[String: Any]` -> `String`/`Date` extractors that pull titles, text, and
/// timestamps out of agent session JSONL/JSON metadata objects (Claude, Grok, and
/// Antigravity histories).
///
/// These transforms are stateless and have no injectable collaborators. The generic
/// string primitive (`firstString`) is shared with `RovoDevMetadataFields` and is
/// reused here instead of being duplicated.
public struct SessionJSONLMetadataReader {
    /// Creates a stateless JSONL metadata reader.
    public init() {}

    /// Returns the first non-empty trimmed text for any of `keys`, resolving array and
    /// nested-block content shapes.
    public func firstText(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let text = firstTextValue(object[key]) else { continue }
            return text
        }
        return nil
    }

    /// Returns a top-level `title`/`prompt`, falling back to message text when the
    /// object reads as a user-authored message.
    public func firstTopLevelTitle(in object: [String: Any]) -> String? {
        if let title = firstText(in: object, keys: ["title", "prompt"]) {
            return title
        }
        guard shouldUseMessageAsTitle(object) else { return nil }
        return firstText(in: object, keys: ["text", "content"])
    }

    /// True when a message object has no role, or its role is `user`.
    public func shouldUseMessageAsTitle(_ message: [String: Any]) -> Bool {
        let role = RovoDevMetadataFields.firstString(from: message, keys: ["role"])
        return role == nil || isUserRole(role)
    }

    /// Extracts a Grok session title, stripping Grok metadata tags and preferring an
    /// explicit `<user_query>` block when present.
    public func grokTitle(in object: [String: Any]) -> String? {
        if shouldUseGrokObjectAsTitle(object) {
            if let title = grokTitleText(firstText(in: object, keys: ["content", "text"])) {
                return title
            }
            if let message = grokTitleText(RovoDevMetadataFields.firstString(from: object, keys: ["message"])) {
                return message
            }
        }
        if let message = object["message"] as? [String: Any],
           shouldUseGrokObjectAsTitle(message) {
            return grokTitleText(firstText(in: message, keys: ["content", "text"]))
        }
        if let messages = object["messages"] as? [[String: Any]] {
            return messages.compactMap { message in
                shouldUseGrokObjectAsTitle(message)
                    ? grokTitleText(firstText(in: message, keys: ["content", "text"]))
                    : nil
            }.first
        }
        return nil
    }

    /// Returns an Antigravity history title from `title`/`prompt`/`display`, falling
    /// back to the generic top-level title.
    public func antigravityHistoryTitle(in object: [String: Any]) -> String? {
        firstText(in: object, keys: ["title", "prompt", "display"])
            ?? firstTopLevelTitle(in: object)
    }

    /// Case-insensitive substring match of `needle` against an Antigravity history's
    /// session id, title, or cwd. An empty needle matches everything.
    public func antigravityHistoryMatchesNeedle(
        needle: String,
        sessionId: String,
        title: String,
        cwd: String?
    ) -> Bool {
        guard !needle.isEmpty else { return true }
        return [sessionId, title, cwd ?? ""].contains { value in
            value.range(of: needle, options: [.caseInsensitive, .literal]) != nil
        }
    }

    /// Resolves an Antigravity history's modified date from its `timestamp`, accepting
    /// millisecond or second epochs and falling back when absent or invalid.
    public func antigravityHistoryModifiedDate(
        in object: [String: Any],
        fallback: Date
    ) -> Date {
        guard let timestamp = antigravityNumericTimestamp(object["timestamp"]) else {
            return fallback
        }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        guard seconds.isFinite, seconds > 0 else { return fallback }
        return Date(timeIntervalSince1970: seconds)
    }

    private func antigravityNumericTimestamp(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func grokTitleText(_ value: String?) -> String? {
        guard let value else { return nil }
        if let userQuery = grokTaggedContent(named: "user_query", in: value) {
            return userQuery
        }
        let withoutMetadata = ["user_info", "git_status", "system-reminder"].reduce(value) { partial, tag in
            removingGrokTaggedContent(named: tag, from: partial)
        }
        return trimmedNonEmpty(withoutMetadata)
    }

    private func grokTaggedContent(named tag: String, in text: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        guard let openRange = text.range(of: openTag) else { return nil }
        let bodyStart = openRange.upperBound
        guard let closeRange = text[bodyStart...].range(of: closeTag) else { return nil }
        return trimmedNonEmpty(String(text[bodyStart..<closeRange.lowerBound]))
    }

    private func removingGrokTaggedContent(named tag: String, from text: String) -> String {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        var result = text
        while let openRange = result.range(of: openTag) {
            let bodyStart = openRange.upperBound
            guard let closeRange = result[bodyStart...].range(of: closeTag) else { break }
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return result
    }

    private func shouldUseGrokObjectAsTitle(_ object: [String: Any]) -> Bool {
        let role = RovoDevMetadataFields.firstString(from: object, keys: ["role", "type"])
        return role == nil || isUserRole(role)
    }

    private func firstTextValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return trimmedNonEmpty(string)
        }
        if let values = value as? [Any] {
            for value in values {
                if let text = firstTextBlock(value) {
                    return text
                }
            }
        }
        if let block = value as? [String: Any] {
            return firstTextBlock(block)
        }
        return nil
    }

    private func firstTextBlock(_ value: Any) -> String? {
        if let string = value as? String {
            return trimmedNonEmpty(string)
        }
        guard let block = value as? [String: Any] else { return nil }
        guard let type = RovoDevMetadataFields.firstString(from: block, keys: ["type"]),
              type.caseInsensitiveCompare("text") == .orderedSame else {
            return nil
        }
        return RovoDevMetadataFields.firstString(from: block, keys: ["text"])
    }

    private func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isUserRole(_ role: String?) -> Bool {
        role?.caseInsensitiveCompare("user") == .orderedSame
    }
}
