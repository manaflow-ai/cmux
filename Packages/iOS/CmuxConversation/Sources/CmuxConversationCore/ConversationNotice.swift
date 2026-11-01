import Foundation

/// A centered system line in a message's place, such as "**You** unsent a
/// message" or "**You** unsent a message. (!) Not Unsent".
///
/// Messages' status templates mark the emphasized run with `#`
/// ("#You# unsent a message", "#%@# unsent a message"); the platforms draw
/// it in the timestamp's bold weight. `failure` is the trailing red,
/// clickable part.
public struct ConversationNotice: Hashable, Sendable {
    public var id: String
    public var messageID: String
    public var leading: String
    public var emphasis: String
    public var trailing: String
    public var failure: String?

    /// `template` may contain one `#…#` run and one `%@`, which takes
    /// `argument`; a template without markers has no emphasis.
    public init(id: String, messageID: String, template: String, argument: String? = nil, failure: String? = nil) {
        self.id = id
        self.messageID = messageID
        self.failure = failure
        func fill(_ part: Substring) -> String {
            guard let argument else { return String(part) }
            return part.replacingOccurrences(of: "%@", with: argument)
        }
        let parts = template.split(separator: "#", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3 {
            leading = fill(parts[0])
            emphasis = fill(parts[1])
            trailing = fill(parts[2])
        } else {
            leading = fill(Substring(template))
            emphasis = ""
            trailing = ""
        }
    }

    /// The whole line as plain text (accessibility, lab dumps).
    public var text: String {
        let line = leading + emphasis + trailing
        guard let failure else { return line }
        return line.replacingOccurrences(of: "%@", with: failure)
    }

    /// The line split around the failure placeholder: the text before it
    /// and after it (the failure substring goes between).
    public var trailingParts: (before: String, after: String) {
        guard failure != nil, let range = trailing.range(of: "%@") else { return (trailing, "") }
        return (String(trailing[..<range.lowerBound]), String(trailing[range.upperBound...]))
    }
}
