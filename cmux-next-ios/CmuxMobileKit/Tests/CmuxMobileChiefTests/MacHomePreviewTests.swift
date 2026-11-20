@testable import CmuxMobileChief
import Foundation
import Testing

/// `plainPreview` strips a preview's Markdown in one pass and takes a regular expression only
/// when it must (cmux-next-ios/design/instant-perf.md, `home_list_first_screen`). These pin its
/// result to the three regular expressions it replaced, and `MacHomeRow.time` to both RFC 3339
/// shapes through the shared formatters.
@Suite("Mac Home preview and time parsing")
struct MacHomePreviewTests {
    /// The earlier implementation, kept here as the reference.
    private func reference(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "```[a-z]*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    @Test("the one-pass preview equals the regular expressions it replaced", arguments: [
        "",
        "plain words only",
        "  leading and trailing  ",
        "two  spaces and   three",
        "a tab\there and a\nnewline\r\nand more",
        "**Done (#12).** The dialer now retries with `backoff`, capped at 30 s.",
        "```swift\nlet a = 1\n```\nafter the fence",
        "``` \n bare fence ```",
        "> quoted _line_ with # heading marks",
        "a single ` backtick and ``two``",
        "non\u{00A0}breaking\u{2003}spaces and caf\u{00E9}",
        "emoji \u{1F600} ** bold ** \u{3000}wide space",
        "line\u{2028}separator and \u{000B}vertical tab",
        "*_`#>",
        "   ",
        "\n\n",
    ])
    func previewMatchesReference(_ text: String) {
        #expect(plainPreview(text) == reference(text))
    }

    @Test("a long generated preview equals the reference")
    func generatedPreviewsMatchReference() {
        let pieces = ["word", " ", "  ", "\n", "\t", "**", "_", "`", "```", "```js", "#", ">", "\u{00A0}", "\u{00E9}", "x y", "."]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<400 {
            var text = ""
            for _ in 0..<24 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                text += pieces[Int((state >> 33) % UInt64(pieces.count))]
            }
            #expect(plainPreview(text) == reference(text), "\(text.debugDescription)")
        }
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
