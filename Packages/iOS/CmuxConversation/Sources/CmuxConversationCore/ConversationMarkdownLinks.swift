import Foundation

/// A link over a span of a message's text (UTF-16 range): Markdown link text
/// the bubble draws underlined and opens on tap.
public struct ConversationTextLink: Sendable, Hashable {
    public var location: Int
    public var length: Int
    public var url: URL

    public init(location: Int, length: Int, url: URL) {
        self.location = location
        self.length = length
        self.url = url
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// Inline Markdown links (`[text](url)`) to their text plus link ranges, as
/// agents write them (`[PR #1](https://…)`, `[a1](cmux://chief/…)`). Bubbles
/// are plain text, so without this the raw syntax and URL show.
// lint:allow namespace-type -- pure helpers
public enum ConversationMarkdownLinks {
    /// `[text](url)`: text without brackets or newlines, url without spaces
    /// or parentheses, with a scheme. An image (`![…](…)`) is left alone.
    nonisolated(unsafe) private static let pattern = try? NSRegularExpression(
        pattern: #"(?<!!)\[([^\[\]\n]+)\]\(([A-Za-z][A-Za-z0-9+.\-]*:[^\s()]+)\)"#
    )

    /// The text with each link replaced by its text, the links, and
    /// `mentions` moved onto the new text (any inside a link's syntax are dropped).
    public static func extract(
        _ text: String,
        mentions: [ConversationMention] = []
    ) -> (text: String, links: [ConversationTextLink], mentions: [ConversationMention]) {
        guard text.contains("]("), let pattern else { return (text, [], mentions) }
        let source = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return (text, [], mentions) }
        let output = NSMutableString()
        var links: [ConversationTextLink] = []
        var cursor = 0
        // (old start, old end, shift after) for remapping mentions.
        var edits: [(start: Int, end: Int, label: NSRange)] = []
        for match in matches {
            let label = source.substring(with: match.range(at: 1))
            guard let url = URL(string: source.substring(with: match.range(at: 2))) else { continue }
            output.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let location = output.length
            output.append(label)
            links.append(ConversationTextLink(location: location, length: (label as NSString).length, url: url))
            edits.append((match.range.location, NSMaxRange(match.range), match.range(at: 1)))
            cursor = NSMaxRange(match.range)
        }
        output.append(source.substring(from: cursor))
        let moved = mentions.compactMap { mention -> ConversationMention? in
            var shift = 0
            for edit in edits {
                if mention.end <= edit.start { break }
                if mention.location >= edit.end {
                    shift += (edit.end - edit.start) - edit.label.length
                    continue
                }
                // Inside a link: keep it only if it lies within the label.
                guard mention.location >= edit.label.location, mention.end <= NSMaxRange(edit.label) else { return nil }
                shift += edit.label.location - edit.start
                break
            }
            return ConversationMention(participantID: mention.participantID, location: mention.location - shift, length: mention.length)
        }
        return (output as String, links, moved)
    }
}

extension ConversationTextLink {
    /// `links` (over a message's whole text) moved onto a bubble that shows
    /// `bodyLength` UTF-16 units of it, starting `offset` units in (a link
    /// card takes its URL out); links outside the bubble text are dropped.
    /// Every bubble builder uses this, so one message always yields the same
    /// links and the same text-cache key.
    public static func bubbleLinks(_ links: [ConversationTextLink], offset: Int = 0, bodyLength: Int) -> [ConversationTextLink] {
        links.compactMap { link in
            let location = link.location - offset
            guard location >= 0, location + link.length <= bodyLength else { return nil }
            return ConversationTextLink(location: location, length: link.length, url: link.url)
        }
    }
}
