@testable import CmuxMobileChief
import Foundation
import Testing

/// `plainPreview` turns a preview's Markdown into its words in one pass with no regular expression
/// (cmux-next-ios/design/instant-perf.md, `home_list_first_screen`; the rules are `MessagePreview`'s,
/// MacHomeMarkdownPreviewTests), and `MacHomeRow.time` parses both RFC 3339 shapes through the shared
/// formatters.
@Suite("Mac Home preview and time parsing")
struct MacHomePreviewTests {
    @Test("a preview shows the words without the Markdown around them", arguments: [
        ("", ""),
        ("plain words only", "plain words only"),
        ("  leading and trailing  ", "leading and trailing"),
        ("two  spaces and   three", "two spaces and three"),
        ("a tab\there and a\nnewline\r\nand more", "a tab here and a newline and more"),
        ("**Done (#12).** The dialer now retries with `backoff`, capped at 30 s.", "Done (#12). The dialer now retries with backoff, capped at 30 s."),
        ("```swift\nlet a = 1\n```\nafter the fence", "let a = 1 after the fence"),
        ("> quoted _line_ with # heading marks", "quoted line with # heading marks"),
        ("non\u{00A0}breaking\u{2003}spaces and caf\u{00E9}", "non breaking spaces and caf\u{00E9}"),
        ("   ", ""),
        ("\n\n", ""),
    ])
    func previewShowsWords(_ text: String, _ expected: String) {
        #expect(plainPreview(text) == expected)
    }

    /// Text with `- + = ! < ~ \ [` and their neighbours: ordinary punctuation stays as written, Markdown goes,
    /// whichever path a line takes (the per-character rules or the plain-run copy). Pinned against
    /// `MessagePreview` as 9d18df05e5c shipped it.
    @Test("punctuation that is not Markdown stays, Markdown around it goes", arguments: [
        ("a - b + c = d!", "a - b + c = d!"),
        ("Wow! It works!!", "Wow! It works!!"),
        ("x <= y && y >= z, a->b, 1 + 1 = 2", "x <= y && y >= z, a->b, 1 + 1 = 2"),
        ("see <https://cmux.com/a> now", "see https://cmux.com/a now"),
        ("Wow! ![shot](a.png) done", "Wow! done"),
        ("~~old~~ new ~ approx ~/src", "old new ~ approx ~/src"),
        ("C\\+\\+ and 1\\*2 and \\[x]", "C++ and 1*2 and [x]"),
        ("[label](https://x.y/(a)) and [not a link] and [x]: y", "label and [not a link] and [x]: y"),
        ("snake_case and __bold__ and *it* and **b**", "snake_case and bold and it and b"),
        ("#hashtag and # not a heading", "#hashtag and # not a heading"),
        ("## Heading ##\ntext", "Heading text"),
        ("- item one\n+ item two\n* item three", "item one item two item three"),
        ("- [x] done task\n- [ ] open task", "done task open task"),
        ("1. first\n2. second", "1. first 2. second"),
        ("Title\n===\nbody\n\n---\n\nafter", "Title body after"),
        ("| a | b |\n|---|---|\n| 1 | 2 |", "Table: a / b"),
        ("run `a | b` then -v --flag=1 +x", "run a | b then -v --flag=1 +x"),
        ("caf\u{00E9} -> na\u{00EF}ve! \u{2014} 3 * 4 = 12", "caf\u{00E9} -> na\u{00EF}ve! \u{2014} 3 * 4 = 12"),
        // A mark combined onto `*` or `\` makes another character, which is text; `é*x*` opens after a letter, so only
        // its closing `*` goes.
        ("e\u{0301}*x* and *\u{0301}y and \\\u{0301}z", "e\u{0301}*x and *\u{0301}y and \\\u{0301}z"),
        ("line one!\r\nline - two\rline = three", "line one! line - two line = three"),
        // U+001C-U+001F are not white space to `Character.isWhitespace`, so they stay; U+000B and U+000C fold.
        ("a\u{1C}b - c\u{0B}\u{0C}d", "a\u{1C}b - c d"),
        ("  - spaced *list*  \t\n  ", "spaced list"),
        ("**Done (#7).** - fixed `code_3`\n[Details](https://cmux.com/d/9) ok. ", "Done (#7). - fixed code_3 Details ok."),
    ])
    func punctuationStays(_ text: String, _ expected: String) {
        #expect(plainPreview(text) == expected)
    }

    @Test("the preview words are the same on every call")
    func chiefWordsStable() {
        #expect(plainPreview("![a](a.png)") == "Image")
        #expect(plainPreview("![a](a.png) ![b](b.png)") == "2 images")
        #expect(plainPreview("|  | |\n|---|---|\n| 1 | 2 |") == "Table")
        #expect(plainPreview("![a](a.png)") == "Image")
    }

    @Test("a row's time parses with and without a fraction, every time it is asked")
    func timeParsesBothShapes() throws {
        let whole = try #require(MacHomeRow.time("2026-11-10T08:48:10Z"))
        let fractional = try #require(MacHomeRow.time("2026-11-10T08:48:10.250Z"))
        #expect(abs(fractional.timeIntervalSince(whole) - 0.25) < 0.001)
        // The shared formatters give the same answer on a later call, in either order.
        #expect(MacHomeRow.time("2026-11-10T08:48:10Z") == whole)
        #expect(MacHomeRow.time("2026-11-10T08:48:10.250Z") == fractional)
        #expect(MacHomeRow.time("2026-11-10T08:48:10+00:00") == whole)
        #expect(MacHomeRow.time("not a time") == nil)
        #expect(MacHomeRow.time(nil) == nil)
    }
}
