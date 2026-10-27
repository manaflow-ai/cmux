import CmuxFuzzSupport
import Foundation
import Testing
@testable import MessagesLabHome

/// p10-stability-191: Home's text passes keep their results on the bounded patterns and scans: a
/// reply quote's words in the original, a link preview's tags, a heading's closing `#`s.
@Suite struct RegexInputBoundsTests {
    // MARK: - Reply quote words

    @Test func wordsAreFoundAcrossAnyWhiteSpace() throws {
        let text = "one  two\t\u{3000}three\u{2028}four"
        let range = try #require(ReplyQuote.wordsRange(["two", "three", "four"], in: text))
        #expect((text as NSString).substring(with: range) == "two\t\u{3000}three\u{2028}four")
    }

    @Test func theFirstPlaceTheWordsStandIsFound() throws {
        // Knuth-Morris-Pratt must fall back inside a partial match: `a a b` starts at the second `a`.
        let text = "a a a b, a a b"
        let range = try #require(ReplyQuote.wordsRange(["a", "a", "b"], in: text))
        #expect(range == NSRange(location: 2, length: 5))
        #expect(ReplyQuote.wordsRange(["a", "c"], in: text) == nil)
        #expect(ReplyQuote.wordsRange(["ab"], in: "a b") == nil)
    }

    @Test func wordsAfterAnEmojiMapBackToTheirUTF16Range() throws {
        let text = "😀 tail of\nit"
        let range = try #require(ReplyQuote.wordsRange(["of", "it"], in: text))
        #expect((text as NSString).substring(with: range) == "of\nit")
    }

    // MARK: - Link preview tags

    @Test func metaAndTitleTagsAreRead() {
        let html = #"<head><meta property="og:title" content="Hello &amp; bye"><meta name='og:site_name' content='Site'/><title>T</title></head>"#
        #expect(LinkPreviews.metaTags(html) == ["og:title": "Hello & bye", "og:site_name": "Site"])
        #expect(LinkPreviews.titleTag(html) == "T")
    }

    @Test func aQuotedValueMayHoldAnAngleBracket() {
        let html = #"<meta property="og:title" content="if a < b then"><meta name='og:description' content='a<3 > b'>"#
            + #"<title data-x="a<b">Hi</title>"#
        #expect(LinkPreviews.metaTags(html) == ["og:title": "if a < b then", "og:description": "a<3 > b"])
        #expect(LinkPreviews.titleTag(html) == "Hi")
    }

    @Test func openTagsBeforeAGoodOneAreSkipped() {
        let junk = String(repeating: "<meta x ", count: 2000) + String(repeating: "<title ", count: 2000)
        let html = junk + #"<meta property="og:title" content="Kept"><title>Also</title>"#
        #expect(LinkPreviews.metaTags(html) == ["og:title": "Kept"])
        #expect(LinkPreviews.titleTag(html) == "Also")
    }

    // MARK: - Heading closing sequence

    @Test func aHeadingsClosingHashesGo() {
        func heading(_ line: String) -> String? { MDBlockParser.atxHeading(MDLine(Substring(line)))?.1 }
        #expect(heading("# Title ##") == "Title")
        #expect(heading("## a#") == "a#")
        #expect(heading("# ###") == "")
        #expect(heading("# x " + String(repeating: "#", count: 5000) + "y") == "x " + String(repeating: "#", count: 5000) + "y")
    }
}

/// The time each pass takes on 64 KiB built to make it rescan: under 50 ms, on every timed attempt
/// (the former patterns took seconds). Timing is not a CI check (Lawrence 2026-10-23): it runs with
/// `CMUX_REGEX_BUDGET_FUZZ=1`, which agents set on the fleet.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_REGEX_BUDGET_FUZZ"] == "1",
                "set CMUX_REGEX_BUDGET_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"))
struct RegexInputBudgetTests {
    static let bytes = 64 << 10
    static let budget = FuzzBudget(perUnit: .milliseconds(50), unitBytes: bytes)

    static func repeated(_ piece: String) -> String {
        FuzzText.truncated(String(repeating: piece, count: bytes / piece.utf8.count + 1), toBytes: bytes)
    }

    @Test func locatingAQuoteIsLinear() throws {
        let text = Self.repeated("a")
        let quote = String(repeating: "a", count: 2000) + " b"
        try Self.budget.check("ReplyQuote.locate", bytes: text.utf8.count) { _ in
            _ = ReplyQuote.locate(quote, in: text)
        }
    }

    @Test func linkPreviewTagsAreLinear() throws {
        for piece in ["<meta x ", "<meta \t ", "<title ", "<meta \"", "<meta '", "\"<meta ", "<meta \"<meta '", "<title \""] {
            let html = Self.repeated(piece)
            try Self.budget.check("LinkPreviews tags of \(piece.debugDescription) repeated", bytes: html.utf8.count) { _ in
                _ = LinkPreviews.metaTags(html)
                _ = LinkPreviews.titleTag(html)
            }
        }
    }

    @Test func aHeadingsClosingHashesAreLinear() throws {
        let line = "# x " + Self.repeated("#") + "y"
        try Self.budget.check("MDBlockParser.atxHeading", bytes: line.utf8.count) { _ in
            _ = MDBlockParser.atxHeading(MDLine(Substring(line)))
        }
    }
}
