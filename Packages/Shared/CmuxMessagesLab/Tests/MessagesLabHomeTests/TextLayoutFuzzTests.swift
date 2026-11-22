import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program phase 3 (plans/cmux-next/crash-elimination.md section 7):
/// property tests for the Home transcript's text layout. An Objective-C range
/// exception ends the test process, so every property is "never throws" plus
/// the invariant that a range is valid for the string it is used on.
/// Seeded, so a failure reproduces from its seed.
@Suite struct TextLayoutFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    }

    /// Markdown tokens plus the text that breaks UTF-16 arithmetic: surrogate
    /// pairs, ZWJ emoji, combining marks, CRLF, right-to-left text.
    static let tokens = [
        "**", "*", "_", "`", "```", "```swift\n", "\n", "\r\n", "  ", "# ", "## ", "- ", "1. ", "> ", "| a | b |\n|---|---|\n",
        "[link](https://example.com)", "<https://x.y>", "word", "longer words here", "👩‍👩‍👧‍👦", "🇯🇵", "e\u{301}", "𝒳", "\u{200D}",
        "שלום", "日本語", "\t", "\\", "~~", "@mention", String(repeating: "x", count: 300),
    ]

    static func document(_ rng: inout Rng) -> String {
        (0..<rng.below(40)).map { _ in rng.pick(tokens) }.joined()
    }

    @Test func randomMarkdownRendersRunsInsideItsTextAndDrawsAtAnyWidth() {
        var rng = Rng(state: 0xC0FFEE)
        for _ in 0..<3_000 {
            let (text, runs) = HomeMarkdown.render(Self.document(&rng))
            let length = (text as NSString).length
            for run in runs {
                #expect(run.start >= 0 && run.length >= 0 && run.start + run.length <= length, "run \(run) outside \(length)")
            }
            let layout = TextLayout.make(text, runs: runs, maxWidth: CGFloat(20 + rng.below(600)))
            _ = layout.attributed(color: .white, linkColor: .white)
            _ = layout.link(at: CGPoint(x: CGFloat(rng.below(600)), y: CGFloat(rng.below(400))))
        }
    }

    @Test func runsThatDoNotFitTheTextAreSkipped() {
        var rng = Rng(state: 7)
        let extremes = [-1, 0, 1, 5, Int.max, Int.min, Int.max - 1]
        for _ in 0..<3_000 {
            let text = Self.document(&rng)
            let length = (text as NSString).length
            let runs = (0..<rng.below(6)).map { _ in
                TextRun(start: rng.below(3) == 0 ? rng.pick(extremes) : rng.below(length + 4),
                        length: rng.below(3) == 0 ? rng.pick(extremes) : rng.below(length + 4),
                        style: rng.pick([["bold"], ["italic"], ["code"], ["bold", "italic"], nil]),
                        link: rng.below(4) == 0 ? "https://example.com" : nil)
            }
            let drawn = TextLayout(text: text, runs: runs, lines: [], width: 0).attributed(color: .white, linkColor: .white)
            #expect(drawn.length == length)
        }
    }

    /// Lines measured for one text and drawn with another (a stale layout
    /// during an edit or a streamed reply): a hit test returns no link instead
    /// of reading past the end.
    @Test func linesFromALongerTextNeverReadPastTheEnd() {
        var rng = Rng(state: 99)
        for _ in 0..<1_000 {
            let long = Self.document(&rng) + String(repeating: "y", count: 80)
            let measured = TextLayout.make(long, runs: [], maxWidth: 120)
            let short = String(long.prefix(rng.below(long.count)))
            let stale = TextLayout(text: short, runs: [], lines: measured.lines, width: measured.width)
            for line in 0..<measured.lines.count {
                _ = stale.link(at: CGPoint(x: 10, y: CGFloat(line) * Fixture.lineHeight + 1))
            }
        }
    }
}
