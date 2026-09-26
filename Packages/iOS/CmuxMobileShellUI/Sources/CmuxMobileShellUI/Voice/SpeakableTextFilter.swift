import Foundation

/// Options controlling how agent markdown is reduced to speakable text.
/// Derived from ``MobileVoiceSettings`` at the call site so the filter stays
/// a pure value-level function.
public struct SpeakableTextOptions: Sendable, Equatable {
    /// Read short fenced code blocks aloud verbatim instead of summarizing
    /// them. Long blocks are always summarized: nobody wants 200 lines of
    /// code performed by a voice.
    public var speakCodeBlocks: Bool
    /// Hard cap on the returned text, applied at a sentence boundary where
    /// possible. The voice model paraphrases, so this bounds cost and how
    /// long the assistant can monologue, not exact speech length.
    public var maximumCharacters: Int

    public init(speakCodeBlocks: Bool = false, maximumCharacters: Int = 700) {
        self.speakCodeBlocks = speakCodeBlocks
        self.maximumCharacters = maximumCharacters
    }
}

/// Reduces agent-authored markdown to text worth speaking aloud.
///
/// Coding agents interleave prose with content that is useless (or hostile)
/// to hear: fenced code, diffs, tables, long inline snippets, URLs, and
/// deep file paths. The filter keeps the prose, replaces the rest with short
/// spoken summaries ("a code block of 41 lines"), and bounds total length.
/// Summaries are produced in English; the voice model paraphrases them into
/// the conversation language.
///
/// Pure and total: never throws, empty input yields empty output.
public enum SpeakableTextFilter {
    /// A fenced code block only qualifies for verbatim reading below this
    /// many lines, and only when the caller opted in.
    public static let maximumSpokenCodeBlockLines = 6
    /// Inline code longer than this is summarized instead of spoken.
    public static let maximumSpokenInlineCodeLength = 48

    public static func speakableText(
        from markdown: String,
        options: SpeakableTextOptions = SpeakableTextOptions()
    ) -> String {
        let collapsed = collapseBlocks(in: markdown, options: options)
        let flattened = collapsed
            .map { Self.flattenInline($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(
                of: "\\s{2,}",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped(flattened, at: max(options.maximumCharacters, 80))
    }

    /// First pass, line-oriented: fold fenced code blocks and table runs into
    /// single summary lines, keeping everything else in order.
    private static func collapseBlocks(
        in markdown: String,
        options: SpeakableTextOptions
    ) -> [String] {
        var output: [String] = []
        var fence: (character: Character, length: Int)?
        var fenceLanguage = ""
        var fenceLines: [String] = []
        var tableRowRun = 0

        func closeTableRun() {
            guard tableRowRun > 0 else { return }
            output.append("(a table with \(tableRowRun) rows.)")
            tableRowRun = 0
        }

        func closeFence() {
            defer {
                fence = nil
                fenceLanguage = ""
                fenceLines = []
            }
            let lines = fenceLines
            if isDiff(language: fenceLanguage, lines: lines) {
                output.append("(a diff changing \(diffChangeCount(in: lines)) lines.)")
                return
            }
            if options.speakCodeBlocks, lines.count <= maximumSpokenCodeBlockLines {
                output.append(contentsOf: lines)
                return
            }
            let label = fenceLanguage.isEmpty ? "code" : fenceLanguage
            output.append("(a \(label) block of \(lines.count) lines.)")
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let openFence = fence {
                // CommonMark: a closing fence uses the SAME character as the
                // opener, at least as long, with nothing else on the line —
                // ``` inside a ~~~ block is content, not a close.
                let run = line.prefix { $0 == openFence.character }
                if run.count >= openFence.length, line.dropFirst(run.count).isEmpty {
                    closeFence()
                } else {
                    fenceLines.append(rawLine)
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                closeTableRun()
                let character = line.first!
                let run = line.prefix { $0 == character }
                fence = (character: character, length: run.count)
                fenceLanguage = line
                    .dropFirst(run.count)
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                continue
            }
            if line.hasPrefix("|"), line.dropFirst().contains("|") {
                // Separator rows (|---|---|) are structure, not content.
                let isSeparator = line.allSatisfy { "|-: ".contains($0) }
                if !isSeparator { tableRowRun += 1 }
                continue
            }
            closeTableRun()
            output.append(rawLine)
        }
        // An unterminated fence at end-of-message (mid-stream truncation)
        // still summarizes rather than leaking raw code into speech.
        if fence != nil { closeFence() }
        closeTableRun()
        return output
    }

    private static func isDiff(language: String, lines: [String]) -> Bool {
        if language == "diff" || language == "patch" { return true }
        guard !lines.isEmpty else { return false }
        let markers = lines.filter { line in
            line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@")
        }
        return markers.count * 2 >= lines.count
    }

    private static func diffChangeCount(in lines: [String]) -> Int {
        lines.filter { line in
            (line.hasPrefix("+") && !line.hasPrefix("+++"))
                || (line.hasPrefix("-") && !line.hasPrefix("---"))
        }.count
    }

    /// Second pass, within one line: strip markdown syntax and shorten the
    /// spans that read badly aloud.
    private static func flattenInline(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        // Headings and blockquotes: keep the words, drop the syntax.
        text = text.replacingOccurrences(
            of: "^(#{1,6}|>)\\s*",
            with: "",
            options: .regularExpression
        )
        // List bullets read as clutter; the prose carries the enumeration.
        text = text.replacingOccurrences(
            of: "^([-*+]|\\d+[.)])\\s+",
            with: "",
            options: .regularExpression
        )
        // Links: speak the label, not the URL.
        text = text.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\([^)]*\\)",
            with: "$1",
            options: .regularExpression
        )
        // Bare URLs: speak the host only.
        text = replacingMatches(
            in: text,
            pattern: "https?://[^\\s)>\\]]+"
        ) { match in
            URL(string: match)?.host.map { "the link at \($0)" } ?? "a link"
        }
        // Inline code: keep short spans, summarize long ones.
        text = replacingMatches(in: text, pattern: "`([^`]*)`") { match in
            let inner = String(match.dropFirst().dropLast())
            return inner.count <= maximumSpokenInlineCodeLength
                ? inner
                : "an inline code snippet"
        }
        // Deep absolute paths: the basename is the part worth hearing.
        text = replacingMatches(
            in: text,
            pattern: "(?<![\\w/])/(?:[\\w.@+-]+/){2,}[\\w.@+-]+"
        ) { match in
            let basename = match.split(separator: "/").last.map(String.init) ?? match
            return "the file \(basename)"
        }
        // Emphasis markers.
        text = text.replacingOccurrences(
            of: "(\\*{1,3}|_{1,3})(\\S[^*_]*?)\\1",
            with: "$2",
            options: .regularExpression
        )
        return text
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        with replacement: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        // Replace back-to-front so earlier ranges stay valid.
        let matches = regex.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).reversed()
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(String(result[range])))
        }
        return result
    }

    private static func capped(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        let hardCut = text.index(text.startIndex, offsetBy: limit)
        let head = text[..<hardCut]
        // Prefer ending on a sentence; fall back to a word boundary. A
        // sentence end only counts when it keeps most of the budget, so one
        // early period doesn't collapse the whole summary.
        if let sentenceEnd = head.lastIndex(where: { ".!?".contains($0) }),
           head.distance(from: head.startIndex, to: sentenceEnd) > limit / 2 {
            return String(head[...sentenceEnd])
        }
        if let wordEnd = head.lastIndex(where: { $0 == " " }) {
            return String(head[..<wordEnd]) + "…"
        }
        return String(head) + "…"
    }
}
