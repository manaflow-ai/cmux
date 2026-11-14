import CmuxConversationCore
import Foundation

/// Markdown strong emphasis (`**bold**`, `__bold__`) in Chief's and agents'
/// text as the bubble's bold runs, the delimiters removed (CMUX-20). Without
/// it the phone shows the raw stars the Mac's Home draws as bold.
///
/// The rules follow the Mac transcript (MessagesLabHome's `HomeMarkdown`):
/// a span opens with two `*` or `_`, its text does not start or end with a
/// space, and `__` sits on word boundaries (snake__case stays as written).
/// Code is never bold: a fenced block (``` or ~~~) and a code span (`` `x` ``)
/// stay as written, and a bold span around a code span leaves the code plain.
/// A backslash escape (`\*`) stays literal. Everything else is untouched.
/// Offsets are UTF-16, like the model's runs, links and mentions.
// lint:allow namespace-type -- pure helpers
enum ChiefMarkdownBold {
    struct Rendered: Equatable {
        var text: String
        var runs: [ConversationTextRun]
        var links: [ConversationTextLink]
        var mentions: [ConversationMention]
    }

    /// `text` with its bold spans as runs; `links` and `mentions` (over
    /// `text`) moved onto the text without delimiters.
    static func render(
        _ text: String,
        links: [ConversationTextLink] = [],
        mentions: [ConversationMention] = []
    ) -> Rendered {
        let unchanged = Rendered(text: text, runs: [], links: links, mentions: mentions)
        guard text.contains("**") || text.contains("__") else { return unchanged }
        var pass = Pass(Array(text))
        pass.document()
        guard !pass.removed.isEmpty else { return unchanged }
        let removed = pass.removed
        // A source offset's place in the new text: minus the removed units before it.
        func moved(_ offset: Int) -> Int {
            offset - removed.reduce(0) { sum, cut in
                cut.location < offset ? sum + min(cut.length, offset - cut.location) : sum
            }
        }
        let newLinks = links.compactMap { link -> ConversationTextLink? in
            let start = moved(link.location), end = moved(link.location + link.length)
            return end > start ? ConversationTextLink(location: start, length: end - start, url: link.url) : nil
        }
        let newMentions = mentions.compactMap { mention -> ConversationMention? in
            let start = moved(mention.location), end = moved(mention.end)
            return end > start ? ConversationMention(participantID: mention.participantID, location: start, length: end - start) : nil
        }
        return Rendered(text: pass.out, runs: pass.runs, links: newLinks, mentions: newMentions)
    }

    /// The live bubble's text: the same bold as the finished message.
    static func attributed(_ text: String) -> AttributedString {
        let rendered = render(text)
        guard !rendered.runs.isEmpty else { return AttributedString(text) }
        let source = rendered.text as NSString
        var result = AttributedString()
        var cursor = 0
        for run in rendered.runs {
            if run.location > cursor {
                result += AttributedString(source.substring(with: NSRange(location: cursor, length: run.location - cursor)))
            }
            var bold = AttributedString(source.substring(with: run.range))
            bold.inlinePresentationIntent = .stronglyEmphasized
            result += bold
            cursor = run.location + run.length
        }
        if cursor < source.length { result += AttributedString(source.substring(from: cursor)) }
        return result
    }

    /// One left-to-right pass: copies characters to `out`, drops bold
    /// delimiters (recorded in `removed`, source UTF-16) and records the bold
    /// output ranges in `runs`.
    private struct Pass {
        let c: [Character]
        /// UTF-16 offset of each character, plus the end.
        let offsets: [Int]
        var out = ""
        var outLength = 0
        var runs: [ConversationTextRun] = []
        var removed: [(location: Int, length: Int)] = []
        var boldDepth = 0
        var inCode = false

        init(_ characters: [Character]) {
            c = characters
            var offsets = [0]
            offsets.reserveCapacity(characters.count + 1)
            for ch in characters { offsets.append(offsets[offsets.count - 1] + ch.utf16.count) }
            self.offsets = offsets
        }

        mutating func document() {
            var i = 0
            var inFence = false
            while i < c.count {
                var end = i
                while end < c.count, !c[end].isNewline { end += 1 }
                let trimmed = String(c[i..<end]).trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    inFence.toggle()
                    copy(i, end)
                } else if inFence {
                    copy(i, end)
                } else {
                    inline(i, end)
                }
                if end < c.count { copy(end, end + 1) }
                i = end + 1
            }
        }

        private mutating func inline(_ from: Int, _ to: Int) {
            var i = from
            while i < to {
                let ch = c[i]
                if ch == "\\", i + 1 < to, c[i + 1].isASCII, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                    copy(i, i + 2); i += 2; continue
                }
                if ch == "`" {
                    let ticks = run(i, to, "`")
                    if let close = closingTicks(i + ticks, to, ticks) {
                        inCode = true
                        copy(i, close + ticks)
                        inCode = false
                        i = close + ticks
                    } else {
                        copy(i, i + ticks); i += ticks
                    }
                    continue
                }
                if ch == "*" || ch == "_" {
                    let n = run(i, to, ch)
                    if n >= 2, let close = closing(i, to, ch) {
                        drop(i, 2)
                        boldDepth += 1
                        inline(i + 2, close)
                        boldDepth -= 1
                        drop(close, 2)
                        i = close + 2
                    } else {
                        copy(i, i + n); i += n
                    }
                    continue
                }
                copy(i, i + 1); i += 1
            }
        }

        /// The `**`/`__` closing a span opened at `i`, skipping code spans.
        private func closing(_ i: Int, _ to: Int, _ ch: Character) -> Int? {
            let start = i + 2
            guard start < to, !c[start].isWhitespace else { return nil }
            if ch == "_", i > 0, c[i - 1].isLetter || c[i - 1].isNumber { return nil }
            var j = start + 1
            while j + 2 <= to {
                if c[j] == "\\" { j += 2; continue }
                if c[j] == "`" {
                    let ticks = run(j, to, "`")
                    j = closingTicks(j + ticks, to, ticks).map { $0 + ticks } ?? j + ticks
                    continue
                }
                if c[j] == ch, c[j + 1] == ch, !c[j - 1].isWhitespace {
                    let after = j + 2
                    if ch != "_" || after >= to || !(c[after].isLetter || c[after].isNumber) { return j }
                }
                j += 1
            }
            return nil
        }

        private func run(_ i: Int, _ to: Int, _ ch: Character) -> Int {
            var n = 0
            while i + n < to, c[i + n] == ch { n += 1 }
            return n
        }

        /// A run of exactly `ticks` backticks at or after `from`.
        private func closingTicks(_ from: Int, _ to: Int, _ ticks: Int) -> Int? {
            var j = from
            while j + ticks <= to {
                if c[j] == "`" {
                    let n = run(j, to, "`")
                    if n == ticks { return j }
                    j += n
                } else {
                    j += 1
                }
            }
            return nil
        }

        private mutating func copy(_ from: Int, _ to: Int) {
            guard from < to else { return }
            let length = offsets[to] - offsets[from]
            out.append(contentsOf: c[from..<to])
            if boldDepth > 0, !inCode {
                if let last = runs.last, last.location + last.length == outLength {
                    runs[runs.count - 1].length += length
                } else {
                    runs.append(ConversationTextRun(location: outLength, length: length, style: .bold))
                }
            }
            outLength += length
        }

        private mutating func drop(_ i: Int, _ n: Int) {
            removed.append((offsets[i], offsets[i + n] - offsets[i]))
        }
    }
}
