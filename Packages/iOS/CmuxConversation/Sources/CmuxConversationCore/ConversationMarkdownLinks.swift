import Foundation

/// A link over a span of a message's text (UTF-16 range): Markdown link text
/// the bubble draws underlined and opens on tap.
public struct ConversationTextLink: Sendable, Hashable, Codable {
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

/// Inline Markdown links (`[text](url)`) and pictures (`![alt](source)`) to
/// their words plus link ranges, as agents write them (`[PR #1](https://…)`,
/// `[a1](cmux://chief/…)`, a screenshot `![before, light](/abs/shot.png)`).
/// Bubbles are plain text, so without this the raw syntax and URL show.
// lint:allow namespace-type -- pure helpers
public enum ConversationMarkdownLinks {
    /// A picture, `![alt](source)` (alt may be empty; the source may sit in angle
    /// brackets and carry a title), or a link, `[text](url)`: text without
    /// brackets or newlines, url without spaces or parentheses, with a scheme.
    /// Groups: 1 alt, 2 source; 3 text, 4 url.
    nonisolated(unsafe) private static let pattern = try? NSRegularExpression(
        pattern: #"!\[([^\[\]\n]*)\]\(<?([^\s()<>]+)>?(?:\s+"[^"\n]*")?\)|(?<!!)\[([^\[\]\n]+)\]\(([A-Za-z][A-Za-z0-9+.\-]*:[^\s()]+)\)"#
    )

    /// What one match shows: its words, where they came from in the source (nil
    /// when made up, a picture's file name), and the link they open, if any.
    private struct Shown {
        var label: String
        var labelRange: NSRange?
        var url: URL?
    }

    private static func shown(_ match: NSTextCheckingResult, in source: NSString) -> Shown? {
        let altRange = match.range(at: 1)
        guard altRange.location != NSNotFound else {
            let label = source.substring(with: match.range(at: 3))
            guard let url = URL(string: source.substring(with: match.range(at: 4))) else { return nil }
            return Shown(label: label, labelRange: match.range(at: 3), url: url)
        }
        // A picture: the phone cannot draw a Mac's file, so it shows the alt text (the
        // file name when there is none), a link only when the picture is on the web.
        let sourceText = source.substring(with: match.range(at: 2))
        let url = URL(string: sourceText).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let alt = source.substring(with: altRange)
        if !alt.trimmingCharacters(in: .whitespaces).isEmpty {
            return Shown(label: alt, labelRange: altRange, url: url)
        }
        let name = sourceText.split(separator: "/").last.map(String.init) ?? sourceText
        return Shown(label: name.removingPercentEncoding ?? name, labelRange: nil, url: url)
    }

    /// The text with each link and picture replaced by its words, the links, and
    /// `mentions` moved onto the new text (any inside the syntax are dropped).
    public static func extract(
        _ text: String,
        mentions: [ConversationMention] = []
    ) -> (text: String, links: [ConversationTextLink], mentions: [ConversationMention]) {
        guard text.contains("]("), let pattern else { return (text, [], mentions) }
        let source = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return (text, [], mentions) }
        let output = NSMutableString(string: "")
        var links: [ConversationTextLink] = []
        var cursor = 0
        // (old start, old end, the label's old range when it is source text, its new length) for remapping mentions.
        var edits: [(start: Int, end: Int, label: NSRange?, length: Int)] = []
        for match in matches {
            guard let shown = shown(match, in: source) else { continue }
            output.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let location = output.length
            output.append(shown.label)
            let length = (shown.label as NSString).length
            if let url = shown.url { links.append(ConversationTextLink(location: location, length: length, url: url)) }
            edits.append((match.range.location, NSMaxRange(match.range), shown.labelRange, length))
            cursor = NSMaxRange(match.range)
        }
        output.append(source.substring(from: cursor))
        let moved = mentions.compactMap { mention -> ConversationMention? in
            var shift = 0
            for edit in edits {
                if mention.end <= edit.start { break }
                if mention.location >= edit.end {
                    shift += (edit.end - edit.start) - edit.length
                    continue
                }
                // Inside a link: keep it only if it lies within a label taken from the text.
                guard let label = edit.label, mention.location >= label.location, mention.end <= NSMaxRange(label) else { return nil }
                shift += label.location - edit.start
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
