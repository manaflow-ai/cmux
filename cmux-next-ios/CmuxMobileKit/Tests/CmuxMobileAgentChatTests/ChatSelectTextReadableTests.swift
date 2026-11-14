@testable import CmuxMobileAgentChat
import Testing

/// Select Text shows an answer as the transcript reads it: no link targets, emphasis marks,
/// code ticks, fences or table rules, with code kept verbatim and table cells tab-separated.
struct ChatSelectTextReadableTests {
    private func readable(_ markdown: String) -> String { ChatSelectText.readable(markdown) }

    @Test func linksImagesAndEmphasisKeepTheirText() {
        #expect(readable("See [the report](https://x.dev/r) and ![chart](c.png).") == "See the report and chart.")
        #expect(readable("**Bold**, ~~gone~~, *em*, _em_ and __strong__.") == "Bold, gone, em, em and strong.")
        // Underscores inside words are text, not emphasis.
        #expect(readable("snake_case_name stays") == "snake_case_name stays")
    }

    @Test func inlineCodeKeepsItsCharacters() {
        #expect(readable("Run `swift test` on `__init__` and `*.swift`.") == "Run swift test on __init__ and *.swift.")
        #expect(readable("Double ``a ` tick`` span") == "Double a ` tick span")
    }

    @Test func fencedCodeIsVerbatimWithoutItsFences() {
        let markdown = "Before\n```swift\nlet x = [a](b) **c**\n```\nAfter **bold**"
        #expect(readable(markdown) == "Before\nlet x = [a](b) **c**\nAfter bold")
        // A longer opening fence closes only on a run as long; a shorter run inside is code.
        #expect(readable("````\n```\nin\n````\nout") == "```\nin\nout")
        #expect(readable("~~~\ncode\n~~~\n*em*") == "code\nem")
    }

    @Test func aLineStartingWithInlineCodeOpensNoFence() {
        let markdown = "```x``` is inline\n**bold** after"
        #expect(readable(markdown) == "x is inline\nbold after")
    }

    @Test func tablesBecomeTabSeparatedCellsWithoutTheirRule() {
        let markdown = "| Area | Result |\n| --- | :---: |\n| WebRTC | **ok** |\n\nAfter"
        #expect(readable(markdown) == "Area\tResult\nWebRTC\tok\n\nAfter")
        // Without a delimiter row, a line with bars is text.
        #expect(readable("a | b |") == "a | b |")
    }

    @Test func blockMarksAndRulesGo() {
        let markdown = "# Title\n> quoted\n- item\n- [x] done\n\n---\nEnd"
        #expect(readable(markdown) == "Title\nquoted\n• item\n• done\n\nEnd")
    }
}
