public import Foundation

/// Pulls human-readable title and field values out of the loosely-typed
/// `[String: Any]` JSON objects that agent session files (Codex/Grok/registered
/// JSONL) deserialize into.
///
/// Agent session files store a conversation as JSON whose shape varies by agent:
/// some put the prompt at the top level, some nest it under a `message` object,
/// some under a `messages` array, and content can be a bare string, an array of
/// typed blocks (`{"type": "text", "text": ...}`), or a single such block. This
/// type owns the pure traversal/extraction math: the first non-empty string for a
/// set of candidate keys, the first text value across the string/array/block
/// shapes, the title chosen from a top-level object or a user-role message, plus
/// the Grok-specific title extraction that strips `<user_info>`/`<git_status>`/
/// `<system-reminder>` metadata tags and prefers a `<user_query>` body.
///
/// Every method is a pure transform over its inputs with no stored state, so a
/// default-constructed parser is sufficient. Mirrors the sibling resolvers
/// (``GrokSessionResolver``/``PiSessionResolver``): an instance value type with
/// instance methods rather than a static-only utility namespace. The
/// `SessionIndexStore` loaders construct one and call its instance methods while
/// projecting on-disk session JSON into session metadata.
public struct AgentSessionFieldParser {
    /// Creates a parser.
    public init() {}

    /// The first non-empty, whitespace-trimmed string value among `keys` in
    /// `object`, or `nil` when none is a non-empty string.
    ///
    /// - Parameters:
    ///   - object: The deserialized JSON object to read from.
    ///   - keys: Candidate keys, tried in order.
    public func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// The first text value among `keys` in `object`, resolving each candidate
    /// through the string/array/block shapes ``firstTextValue(_:)`` understands.
    ///
    /// - Parameters:
    ///   - object: The deserialized JSON object to read from.
    ///   - keys: Candidate keys, tried in order.
    public func firstText(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let text = firstTextValue(object[key]) else { continue }
            return text
        }
        return nil
    }

    /// The title for a top-level session object: a `title`/`prompt` value if
    /// present, otherwise the `text`/`content` of the object when it reads as a
    /// user-role message.
    ///
    /// - Parameter object: The top-level session JSON object.
    public func firstTopLevelTitle(in object: [String: Any]) -> String? {
        if let title = firstText(in: object, keys: ["title", "prompt"]) {
            return title
        }
        guard shouldUseMessageAsTitle(object) else { return nil }
        return firstText(in: object, keys: ["text", "content"])
    }

    /// The Grok session title: the first usable title from the top-level object,
    /// its nested `message`, or its `messages` array, cleaned by
    /// ``grokTitleText(_:)``.
    ///
    /// - Parameter object: The top-level Grok session JSON object.
    public func grokTitle(in object: [String: Any]) -> String? {
        if shouldUseGrokObjectAsTitle(object) {
            if let title = grokTitleText(firstText(in: object, keys: ["content", "text"])) {
                return title
            }
            if let message = grokTitleText(firstString(in: object, keys: ["message"])) {
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

    /// Cleans a Grok message body into a title: prefers a `<user_query>` tag's
    /// body, otherwise strips `<user_info>`/`<git_status>`/`<system-reminder>`
    /// metadata tags and returns the trimmed remainder, or `nil` when empty.
    ///
    /// - Parameter value: The raw Grok message body, or `nil`.
    public func grokTitleText(_ value: String?) -> String? {
        guard let value else { return nil }
        if let userQuery = grokTaggedContent(named: "user_query", in: value) {
            return userQuery
        }
        let withoutMetadata = ["user_info", "git_status", "system-reminder"].reduce(value) { partial, tag in
            removingGrokTaggedContent(named: tag, from: partial)
        }
        return trimmedNonEmpty(withoutMetadata)
    }

    /// The trimmed body of the first `<tag>...</tag>` pair in `text`, or `nil`
    /// when the tag is absent or its body is empty.
    ///
    /// - Parameters:
    ///   - tag: The tag name (without angle brackets).
    ///   - text: The text to search.
    public func grokTaggedContent(named tag: String, in text: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        guard let openRange = text.range(of: openTag) else { return nil }
        let bodyStart = openRange.upperBound
        guard let closeRange = text[bodyStart...].range(of: closeTag) else { return nil }
        return trimmedNonEmpty(String(text[bodyStart..<closeRange.lowerBound]))
    }

    /// `text` with every `<tag>...</tag>` pair (including the tags) removed.
    ///
    /// - Parameters:
    ///   - tag: The tag name (without angle brackets).
    ///   - text: The text to strip from.
    public func removingGrokTaggedContent(named tag: String, from text: String) -> String {
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

    /// Whether a Grok object should supply the title: true when it has no
    /// `role`/`type`, or its role reads as a user role.
    ///
    /// - Parameter object: The Grok message object.
    public func shouldUseGrokObjectAsTitle(_ object: [String: Any]) -> Bool {
        let role = firstString(in: object, keys: ["role", "type"])
        return role == nil || isUserRole(role)
    }

    /// The first text value for a loosely-typed JSON value: a trimmed string, the
    /// first text block in an array, or a single text block.
    ///
    /// - Parameter value: The JSON value (string, array, or object), or `nil`.
    public func firstTextValue(_ value: Any?) -> String? {
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

    /// The text of one content block: a trimmed bare string, or the `text` of a
    /// `{"type": "text", "text": ...}` object, otherwise `nil`.
    ///
    /// - Parameter value: A single content block (string or object).
    public func firstTextBlock(_ value: Any) -> String? {
        if let string = value as? String {
            return trimmedNonEmpty(string)
        }
        guard let block = value as? [String: Any] else { return nil }
        guard let type = firstString(in: block, keys: ["type"]),
              type.caseInsensitiveCompare("text") == .orderedSame else {
            return nil
        }
        return firstString(in: block, keys: ["text"])
    }

    /// `value` trimmed of surrounding whitespace and newlines, or `nil` when the
    /// result is empty.
    ///
    /// - Parameter value: The string to trim.
    public func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether a message should supply the title: true when it has no `role`, or
    /// its role reads as a user role.
    ///
    /// - Parameter message: The message object.
    public func shouldUseMessageAsTitle(_ message: [String: Any]) -> Bool {
        let role = firstString(in: message, keys: ["role"])
        return role == nil || isUserRole(role)
    }

    /// Whether `role` is the user role (case-insensitive `"user"`).
    ///
    /// - Parameter role: The role string, or `nil`.
    public func isUserRole(_ role: String?) -> Bool {
        role?.caseInsensitiveCompare("user") == .orderedSame
    }
}
