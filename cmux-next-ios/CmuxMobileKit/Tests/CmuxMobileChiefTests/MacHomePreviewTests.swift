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
