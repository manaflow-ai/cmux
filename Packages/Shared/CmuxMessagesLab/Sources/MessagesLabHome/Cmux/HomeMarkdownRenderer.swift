import Foundation

/// `HomeMarkdown.render` for a text that grows at its end (an agent's streaming reply): the
/// same output, but a text that extends the last one resumes after the last line both share
/// (HomeMarkdown.Pass), and other lines come from a line cache. A token then renders its own
/// line, not the reply (plans/cmux-next/home-streaming-perf-DESIGN.md, 2).
///
/// Main thread only (the projection's).
final class HomeMarkdownRenderer {
    let lines: HomeMarkdownLineCache
    /// The source of the complete lines the kept pass rendered (through their last newline).
    private var kept = ""
    private var keptPass: HomeMarkdown.Pass
    /// Renders that resumed after kept lines, for tests.
    private(set) var resumes = 0

    init(lines: HomeMarkdownLineCache = HomeMarkdownLineCache()) {
        self.lines = lines
        keptPass = HomeMarkdown.Pass(chips: lines.chips)
    }

    func render(_ source: String) -> (text: String, runs: [TextRun]) {
        var pass: HomeMarkdown.Pass
        var rest: Substring
        let n = kept.utf8.count
        if n > 0, source.utf8.count >= n, Self.hasPrefix(source, kept) {
            pass = keptPass
            rest = Substring(source.utf8.dropFirst(n))
            resumes += 1
        } else {
            pass = HomeMarkdown.Pass(chips: lines.chips)
            rest = Substring(source)
        }
        // Every line but the last ends at a newline: those are kept for the next text. A CR LF
        // pair is one Character and no line break to `split(separator: "\n")`: it stays in its line.
        var lineStart = rest.startIndex
        var sawNewline = false
        var i = rest.utf8.startIndex
        while let nl = rest.utf8.slice(from: i).firstIndex(of: 10) {
            i = rest.utf8.index(after: nl)
            if nl > rest.utf8.startIndex, rest.utf8[checked: rest.utf8.index(before: nl)] == 13 { continue }
            pass.line(rest.slice(lineStart, nl), lines: lines)
            lineStart = i
            sawNewline = true
        }
        if sawNewline {
            kept = String(source.slice(source.startIndex, lineStart))
            keptPass = pass
        }
        pass.line(rest.slice(from: lineStart), lines: lines)
        return (pass.out.text, pass.out.runs)
    }

    /// Whether `source` starts with `prefix`, byte for byte: one `memcmp` (the generic
    /// `starts(with:)` over two UTF-8 views took a third of a streaming frame at 50 KB).
    private static func hasPrefix(_ source: String, _ prefix: String) -> Bool {
        var s = source, p = prefix
        s.makeContiguousUTF8()
        p.makeContiguousUTF8()
        return s.utf8.withContiguousStorageIfAvailable { sb in
            p.utf8.withContiguousStorageIfAvailable { pb -> Bool in
                guard pb.count <= sb.count else { return false }
                guard let sa = sb.baseAddress, let pa = pb.baseAddress else { return pb.isEmpty }
                return memcmp(sa, pa, pb.count) == 0
            } ?? false
        } ?? false
    }
}
