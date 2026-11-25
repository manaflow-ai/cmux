import Foundation
import Testing
@testable import MessagesLabHome

/// CMUX-20: the Mac's Home draws `**bold**` and `__bold__` as bold and never bolds code. The
/// iPhone's Chief (cmux-next-ios ChiefMarkdownBoldTests) checks the same inputs, so the two agree.
@Suite(.serialized) struct HomeMarkdownBoldParityTests {
    init() { HomeMarkdownPolicy.install() }

    /// The shown text and the substrings of its bold, non-code runs.
    func bold(_ markdown: String) -> (text: String, bold: [String]) {
        let (text, runs) = HomeMarkdown.render(markdown)
        let ns = text as NSString
        let bold = runs.filter { ($0.style ?? []).contains("bold") && !($0.style ?? []).contains("code") }
            .map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) }
        return (text, bold)
    }

    @Test func strongEmphasisIsBold() {
        let rendered = bold("**#36125 is green** at 64d6b1b and __done__.")
        #expect(rendered.text == "#36125 is green at 64d6b1b and done.")
        #expect(rendered.bold == ["#36125 is green", "done"])
    }

    @Test func codeIsNeverBold() {
        let span = bold("Run `**not bold**` then **see `cmux ls` now**.")
        #expect(span.text == "Run **not bold** then see cmux ls now.")
        #expect(span.bold == ["see ", " now"])
        let fenced = bold("Before **a**\n```\nlet x = **y**\n```\nAfter **b**")
        #expect(fenced.bold == ["a", "b"])
        #expect(fenced.text.contains("let x = **y**"))
    }

    @Test func plainMarkdownIsNotBold() {
        for text in ["snake__case__name and file__name", "** spaced ** and **unclosed", "*italic* and _also_"] {
            #expect(bold(text).bold.isEmpty, "\(text)")
        }
    }
}
