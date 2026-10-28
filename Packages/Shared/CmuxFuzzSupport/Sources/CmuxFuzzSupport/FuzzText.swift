import Foundation

/// Hostile text for text layout, Markdown and render suites: Markdown syntax with
/// fences left open or closed, tables with ragged columns, ZWJ emoji, combining marks, bidi controls,
/// CRLF, lone CR and Unicode line ends, and huge lines with and without break opportunities. Every
/// choice comes from the run's `FuzzRNG`, so a replay line rebuilds the same text and a libFuzzer
/// input (`FuzzRNG(replaying:)`) drives the same generator. The pieces follow Chromium's text fuzz
/// dictionaries (third_party/blink/renderer/platform/fonts/shaping/harfbuzz_shaper_fuzzer.cc feeds
/// shaping with mixed scripts and emoji; testing/libfuzzer/fuzzers/dicts/ hold the syntax tokens).
public struct FuzzText: Sendable {
    /// Upper bound on the UTF-8 size of one generated text.
    public var maxBytes: Int

    public init(maxBytes: Int) {
        self.maxBytes = max(maxBytes, 0)
    }

    /// Markdown syntax, CommonMark and GitHub's extensions, alone and in the combinations that open and
    /// close blocks and delimiter runs.
    public static let markdownTokens: [String] = [
        "# ", "###### ", "#", "####### ", "> ", ">", "> > ", "- ", "* ", "+ ", "1. ", "12) ", "999999999. ",
        "- [ ] ", "- [x] ", "  - ", "    ", "\t", "**", "*", "__", "_", "~~", "~", "`", "``", "***", "---", "===",
        "| ", " |", "|", "|---|", ":--", "--:", ":-:", "[", "]", "](", ")", "![", "[^1]", "[ref]: https://example.com",
        "[ref]", "<", ">", "<https://example.com>", "https://example.com/a_b*c", "www.example.com", "a@example.com",
        "&amp;", "&#x1F600;", "&#0;", "&", "\\", "\\*", "\\`", "<br>", "<div>", "</div>", "<!-- ", " -->", "$$", "$",
    ]

    /// Scripts, clusters and controls that change shaping, line breaking and UTF-16 lengths.
    public static let unicodeTokens: [String] = [
        "\u{1F469}\u{200D}\u{1F4BB}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}",
        "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", "\u{1F9D1}\u{1F3FD}\u{200D}\u{1F680}", "\u{2764}\u{FE0F}\u{200D}\u{1F525}",
        "\u{1FAF1}\u{1F3FB}\u{200D}\u{1FAF2}\u{1F3FF}", "\u{200D}", "\u{1F1FA}\u{1F1F8}", "\u{1F1FA}", "1\u{FE0F}\u{20E3}",
        "\u{1F600}", "\u{FE0F}", "\u{E0067}\u{E007F}", "e\u{301}", "a\u{301}\u{302}\u{303}\u{304}\u{305}",
        "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}", "\u{05E9}\u{05DC}\u{05D5}\u{05DD}", "\u{202E}", "\u{202C}",
        "\u{2066}", "\u{2069}", "\u{200E}", "\u{200F}", "\u{200B}", "\u{FEFF}", "\u{00AD}", "\u{0000}", "\u{FFFD}",
        "\u{6F22}\u{5B57}", "\u{D55C}\u{AD6D}\u{C5B4}", "\u{304B}\u{306A}", "\u{FDFA}", "\u{1242B}",
        "\u{0915}\u{094D}\u{200D}\u{0937}", "\u{0B95}\u{0BCD}", "\u{0E01}\u{0E34}\u{0E48}", "\u{1D400}", "\u{2603}",
    ]

    /// Line ends a renderer meets: LF, CRLF, a lone CR, blank lines, NEL and the Unicode line and paragraph separators.
    public static let lineEnds: [String] = ["\n", "\r\n", "\r", "\n\n", "\r\n\r\n", "\u{85}", "\u{2028}", "\u{2029}"]

    public static let words: [String] = ["word", "Hgjpqy", "the", "fleet", "a", "x", "supercalifragilistic", "cmux-ci", "42"]

    /// Fence info strings, the Mermaid one included (Home splits diagrams out of the text).
    public static let fenceLanguages: [String] = ["", "swift", "rust", "diff", "mermaid", "json", "{}", "``"]

    /// One text of at most `maxBytes` UTF-8 bytes. It stops early once a replayed input is used up.
    public func text(_ rng: inout FuzzRNG) -> String {
        let target = rng.int(in: 0...maxBytes)
        var out = ""
        var bytes = 0
        while bytes < target, !rng.isExhausted {
            let next = piece(room: target - bytes, &rng)
            out += next
            bytes += next.utf8.count
        }
        return Self.truncated(out, toBytes: maxBytes)
    }

    /// One piece of a text: a syntax token, a word, a shaping hazard, a line end, a fence, a table
    /// or (rarely) a huge line, no longer than `room` bytes when it is a huge line.
    func piece(room: Int, _ rng: inout FuzzRNG) -> String {
        switch rng.below(10) {
        case 0, 1: return Self.markdownTokens[rng.below(Self.markdownTokens.count)]
        case 2, 3: return Self.words[rng.below(Self.words.count)] + (rng.oneIn(4) ? "" : " ")
        case 4: return Self.unicodeTokens[rng.below(Self.unicodeTokens.count)]
        case 5, 6: return Self.lineEnds[rng.below(Self.lineEnds.count)]
        case 7: return fence(&rng)
        case 8: return table(&rng)
        default:
            guard room > 64, rng.oneIn(3) else { return Self.words[rng.below(Self.words.count)] + " " }
            return Self.hugeLine(bytes: rng.int(in: 64...min(room, 1 << 16)), &rng)
        }
    }

    /// A fenced code block, closed or left open (a stream that has not sent its closing fence yet).
    func fence(_ rng: inout FuzzRNG) -> String {
        let marker = rng.bool() ? "```" : "~~~"
        let end = Self.lineEnds[rng.below(3)]
        var out = marker + Self.fenceLanguages[rng.below(Self.fenceLanguages.count)] + end
        for _ in 0..<rng.below(6) {
            out += String(repeating: " ", count: max(0, rng.below(9))) + Self.words[rng.below(Self.words.count)]
            out += rng.oneIn(3) ? Self.unicodeTokens[rng.below(Self.unicodeTokens.count)] : " = 1;"
            out += end
        }
        if !rng.oneIn(3) { out += marker + end }
        return out
    }

    /// A pipe table whose rows may have fewer or more cells than its header.
    func table(_ rng: inout FuzzRNG) -> String {
        let columns = 1 + rng.below(6)
        let end = Self.lineEnds[rng.below(3)]
        func row(_ cells: Int, _ rng: inout FuzzRNG) -> String {
            "|" + (0..<cells).map { _ in " " + Self.words[rng.below(Self.words.count)] + " |" }.joined() + end
        }
        let aligns = [" --- |", " :-- |", " --: |", " :-: |"]
        var out = row(columns, &rng) + "|" + (0..<columns).map { _ in aligns[rng.below(aligns.count)] }.joined() + end
        for _ in 0..<rng.below(5) { out += row(max(0, columns + rng.int(in: -1...2)), &rng) }
        return out
    }

    /// One line of about `bytes` UTF-8 bytes and no line end, in a shape that stresses a different part
    /// of line breaking: one unbreakable word, words, CJK (a break opportunity everywhere), ZWJ emoji
    /// without spaces, one base character under thousands of combining marks, delimiter runs and nested
    /// brackets (the inline parser's worst cases), or a quote nested hundreds deep.
    public static func hugeLine(bytes: Int, _ rng: inout FuzzRNG) -> String {
        let n = max(bytes, 1)
        func repeated(_ unit: String) -> String {
            String(repeating: unit, count: max(1, n / max(unit.utf8.count, 1)))
        }
        switch rng.below(10) {
        case 0: return repeated("x")
        case 1: return repeated("lorem ")
        case 2: return repeated("\u{6F22}\u{5B57}\u{304B}\u{306A}")
        case 3: return repeated("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}")
        case 4: return "Z" + repeated("\u{301}")
        case 5: return repeated(["*", "_", "`", "~"][rng.below(4)])
        case 6: return repeated("[")
        case 7: return repeated("> ")
        case 8: return repeated("a\u{200B}")
        default: return repeated("\u{0627}\u{0644} ab ")
        }
    }

    /// A text of exactly one shape near `bytes` UTF-8 bytes (the time-budget inputs): a huge line,
    /// short lines, a Markdown document, emoji or CRLF text, so each shape is measured on its own.
    public static func sized(bytes: Int, _ rng: inout FuzzRNG) -> String {
        let generator = FuzzText(maxBytes: bytes)
        var out = ""
        switch rng.below(6) {
        case 0:
            out = hugeLine(bytes: bytes, &rng)
        case 1:
            while out.utf8.count < bytes { out += words[rng.below(words.count)] + "\n" }
        case 2:
            while out.utf8.count < bytes, !rng.isExhausted { out += generator.piece(room: 0, &rng) }
        case 3:
            while out.utf8.count < bytes { out += unicodeTokens[rng.below(unicodeTokens.count)] + " " }
        case 4:
            while out.utf8.count < bytes { out += "\(words[rng.below(words.count)]) \(words[rng.below(words.count)])\r\n" }
        default:
            // Every block names its section, so no two blocks are equal: a layout cache keyed by block
            // content (Home's Markdown block cache) cannot serve one section from another.
            var section = 0
            while out.utf8.count < bytes {
                section += 1
                out += "## Step \(section)\n\nRebase step \(section) on **main**, run `cmux-ci`, then *report*.\n\n"
                out += "- item \(section).1\n- item [\(section).2](https://example.com/\(section))\n\n"
                out += "```swift\nlet value = \(section)\n```\n\n"
                out += "| Suite \(section) | Result |\n|---|---|\n| one | passed \(section) |\n\n"
            }
        }
        // A replayed input that ran out leaves the loops above short; the text is what it built.
        return truncated(out, toBytes: bytes)
    }

    /// Prefixes of `text` as a stream delivers them: `steps` cuts at increasing Unicode scalar offsets
    /// (so a cut can split a ZWJ sequence, a CRLF pair or a fence marker), then the whole text.
    public static func stream(_ text: String, steps: Int, _ rng: inout FuzzRNG) -> [String] {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return [text] }
        var cuts = Set<Int>()
        for _ in 0..<max(steps, 0) { cuts.insert(rng.int(in: 0...scalars.count)) }
        cuts.insert(scalars.count)
        return cuts.sorted().map { string(scalars.prefix($0)) }
    }

    /// `text` after one edit a stream or a person makes between a measurement and a draw: its end
    /// rewritten (a Markdown style that closes shortens the text), a piece inserted or a range deleted
    /// anywhere, or its line ends converted.
    public func edit(_ text: String, _ rng: inout FuzzRNG) -> String {
        var scalars = Array(text.unicodeScalars)
        switch rng.below(5) {
        case 0:
            let cut = min(scalars.count, rng.below(65))
            scalars.removeLast(cut)
            scalars += Array(Self.markdownTokens[rng.below(Self.markdownTokens.count)].unicodeScalars)
        case 1:
            let at = rng.int(in: 0...scalars.count)
            scalars.insert(contentsOf: Array(piece(room: 4096, &rng).unicodeScalars), at: at)
        case 2:
            let from = rng.int(in: 0...scalars.count)
            let to = rng.int(in: from...min(scalars.count, from + 512))
            scalars.removeSubrange(from..<to)
        case 3:
            return Self.truncated(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"),
                                  toBytes: maxBytes)
        default:
            scalars += Array(piece(room: 512, &rng).unicodeScalars)
        }
        return Self.truncated(Self.string(scalars[...]), toBytes: maxBytes)
    }

    /// `text` cut to at most `bytes` UTF-8 bytes at a scalar boundary.
    public static func truncated(_ text: String, toBytes bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var out = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            let size = UTF8.width(scalar)
            if count + size > bytes { break }
            out.append(scalar)
            count += size
        }
        return String(out)
    }

    static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
