import Foundation

/// Reply with Selection: the part of one bubble's text the person selected,
/// handed to the host so it can reply to that message with only those words
/// quoted (the Mac Chief's Reply to Selection, `home.replyToSelection`).
public struct ConversationSelectionReply: Sendable, Hashable {
    /// The message the selection is in; the reply answers it.
    public var messageID: String
    /// The selected words as the bubble shows them, without the blank space
    /// around them.
    public var text: String

    public init(messageID: String, text: String) {
        self.messageID = messageID
        self.text = text
    }

    /// A selection longer than this many characters is quoted cut, with an
    /// ellipsis (the Mac's `ReplyQuote.maxQuoted`).
    public static let maxQuoted = 1_000

    /// The selection `range` (UTF-16, as a text view reports it) of the
    /// bubble's shown `text`; nil when it selects nothing but blank space or
    /// falls outside the text.
    public init?(messageID: String, text: String, selectedRange range: NSRange) {
        guard range.location != NSNotFound, range.length > 0,
              let bounds = Range(range, in: text) else { return nil }
        let excerpt = text[bounds].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { return nil }
        self.init(messageID: messageID, text: excerpt.count > Self.maxQuoted ? Self.cut(excerpt, limit: Self.maxQuoted) : excerpt)
    }

    /// The first `limit` characters, back to the last word end when one is
    /// in the second half, then "…" (the Mac's `ReplyQuote.cut`).
    static func cut(_ text: String, limit: Int) -> String {
        let head = text.prefix(max(1, limit - 1))
        let word = head.lastIndex(where: { $0.isWhitespace })
            .map { head.distance(from: head.startIndex, to: $0) }
            .flatMap { length in length > limit / 2 ? head.prefix(length) : nil } ?? head
        return word.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The excerpt as a Markdown quote ("> " before each line, ">" alone on
    /// an empty one), then an empty line for the reply: the Mac's
    /// `HomeMessageRouting.quoted`, so a quote reads the same from either.
    public var markdownQuote: String {
        let lines = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        return lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n") + "\n\n"
    }
}
