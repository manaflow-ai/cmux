// cmux: Reply to Selection (plans/cmux-next/reply-to-selection-DESIGN.md). Not a vendored file.
import Foundation

/// The part of one message a reply answers: what the person selected before
/// Reply to Selection.
///
/// On the wire a quote is a Markdown blockquote at the start of the reply's
/// text (`quoted(reply:)`), so every owner stores it as written and the Chief
/// reads it with no schema change; `split` reads it back for display. The
/// range is this Mac's (the selection's row and offsets): a sent quote finds its
/// words again in the original's shown text (`locate`).
struct ReplyQuote: Equatable {
    /// The message and part the selection is in (its first selected row).
    var source: PartRef
    /// The first selected row's key and its range (UTF-16, shown text).
    var key: String
    var range: NSRange
    /// The selected text as shown, trimmed.
    var text: String

    /// A quote longer than this many characters goes out cut, with an ellipsis.
    static let maxQuoted = 1_000
    /// The sent bubble shows at most this many characters of the quote.
    static let bubbleLimit = 120
    /// The composer card shows at most this many characters (two lines at most there).
    static let cardLimit = 160

    /// The quote of a transcript selection: nil when nothing but white space is
    /// selected, or when the selection reaches past message `messageId` (a quote
    /// has one source).
    init?(selection: [(key: String, range: NSRange, text: String)], messageId: ID, partIndex: Int) {
        guard let first = selection.first,
              selection.allSatisfy({ RowBuilder.key($0.key, belongsTo: messageId) }) else { return nil }
        let joined = selection.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        source = PartRef(messageId: messageId, partIndex: partIndex)
        key = first.key
        range = first.range
        text = joined.count > Self.maxQuoted ? Self.cut(joined, limit: Self.maxQuoted) : joined
    }

    /// The reply as it goes out: the quote as a Markdown blockquote, a blank
    /// line, then what the person typed.
    func quoted(reply: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }
        return lines.joined(separator: "\n") + "\n\n" + reply
    }

    /// A text that starts with a blockquote: the quote (markers removed) and the
    /// rest (after the blank line). Nil when the text does not start with `>`,
    /// or the quote is empty.
    static func split(_ text: String) -> (quote: String, body: String)? {
        guard text.hasPrefix(">") else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let quoted = lines.prefix { $0.hasPrefix(">") }
        let quote = quoted.map { line -> Substring in
            let rest = line.dropFirst()
            return rest.hasPrefix(" ") ? rest.dropFirst() : rest
        }
        let q = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let body = lines.dropFirst(quoted.count).joined(separator: "\n")
        return (q, body.trimmingCharacters(in: .newlines))
    }

    /// The text white space collapsed to single spaces, at most `limit`
    /// characters: a longer one is cut at a word end with an ellipsis.
    static func excerpt(_ s: String, limit: Int) -> String {
        let flat = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return flat.count > limit ? cut(flat, limit: limit) : flat
    }

    /// The first `limit` characters, back to the last word end when one is near, and "…".
    private static func cut(_ s: String, limit: Int) -> String {
        let head = s.prefix(max(1, limit - 1))
        let word = head.lastIndex(where: { $0.isWhitespace })
            .map { head.distance(from: head.startIndex, to: $0) }
            .flatMap { n in n > limit / 2 ? head.prefix(n) : nil } ?? head
        return word.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Where a quote's words are in `text` (UTF-16): the exact text first, then
    /// the same words with any white space between them (the original reflowed,
    /// or the quote crossed lines), then the words before a cut's ellipsis.
    /// Both searches are linear in the text and the quote (p10-stability-191).
    static func locate(_ quote: String, in text: String) -> NSRange? {
        let needle = Array(quote.utf16)
        if let exact = firstIndex(of: needle, in: Array(text.utf16)) {
            return NSRange(location: exact, length: needle.count)
        }
        var words = quote.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        if let last = words.last, last.hasSuffix("…") {
            let kept = String(last.dropLast())
            words.removeLast()
            if !kept.isEmpty { words.append(kept) }
        }
        guard !words.isEmpty else { return nil }
        return wordsRange(words, in: text)
    }

    /// Where `words` first stand in `text` in order with white space between them (UTF-16), as
    /// `w1\s+w2…` would find them, in time linear in both: the text with each white space run as
    /// one space, searched for the words joined by spaces (Knuth-Morris-Pratt). The regex tried
    /// the quote at every position of the text, O(text × quote) on repetitive text
    /// (p10-stability-191).
    static func wordsRange(_ words: [String], in text: String) -> NSRange? {
        var collapsed: [UInt16] = []
        var origin: [Int] = [] // the text offset of each collapsed unit
        var inSpace = false
        for (offset, unit) in text.utf16.enumerated() {
            let space = isSpace(unit)
            if !(space && inSpace) {
                collapsed.append(space ? 32 : unit)
                origin.append(offset)
            }
            inSpace = space
        }
        let needle = Array(words.joined(separator: " ").utf16)
        // The needle starts and ends inside a word, never on a collapsed run, so both ends map back one to one.
        guard let found = firstIndex(of: needle, in: collapsed), let start = origin[checked: found],
              let last = origin[checked: found + needle.count - 1] else { return nil }
        return NSRange(location: start, length: last + 1 - start)
    }

    /// White space as the quote's words are split on (a word holds none).
    private static func isSpace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }

    /// The first offset of `needle` in `haystack` (Knuth-Morris-Pratt), or nil.
    private static func firstIndex(of needle: [UInt16], in haystack: [UInt16]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        // border[i]: the longest proper prefix of needle[0...i] that is also its suffix.
        var border: [Int] = [0]
        var length = 0
        for unit in needle.dropFirst() {
            while length > 0, needle[checked: length] != unit { length = border[checked: length - 1] ?? 0 }
            if needle[checked: length] == unit { length += 1 }
            border.append(length)
        }
        var matched = 0
        for (position, unit) in haystack.enumerated() {
            while matched > 0, needle[checked: matched] != unit { matched = border[checked: matched - 1] ?? 0 }
            if needle[checked: matched] == unit { matched += 1 }
            if matched == needle.count { return position - needle.count + 1 }
        }
        return nil
    }

    /// A quote as the top of a sent bubble: `“excerpt”` and the run that styles it (`quote`).
    static func head(_ quote: String) -> (text: String, run: TextRun) {
        let head = "\u{201C}" + excerpt(quote, limit: bubbleLimit) + "\u{201D}"
        return (head, TextRun(start: 0, length: (head as NSString).length, style: ["quote"]))
    }
}
