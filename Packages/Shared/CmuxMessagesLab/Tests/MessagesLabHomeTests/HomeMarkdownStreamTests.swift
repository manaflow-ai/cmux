import Testing
@testable import MessagesLabHome

/// An agent's running reply grows a few words at a time: its last line may hold an opener whose
/// closer has not arrived yet, and no raw marker is drawn there (`streaming`, the draft bubble).
/// A posted message is never streaming: there an unclosed opener stays as written.
@Suite struct HomeMarkdownStreamTests {
    static func styles(_ r: (text: String, runs: [TextRun])) -> [String] {
        r.runs.map { "\($0.start)+\($0.length):\(($0.style ?? []).joined(separator: ","))" }
    }

    // MARK: A running reply (streaming)

    @Test func aStreamingUnclosedBoldOnTheLastLineStylesTheRest() {
        let r = HomeMarkdown.render("the **focused", streaming: true)
        #expect(r.text == "the focused")
        #expect(Self.styles(r) == ["4+7:bold"])
        let more = HomeMarkdown.render("the **focused tests", streaming: true)
        #expect(more.text == "the focused tests")
        #expect(Self.styles(more) == ["4+13:bold"])
    }

    @Test func aStreamingUnclosedCodeOrItalicOnTheLastLine() {
        #expect(HomeMarkdown.render("run `swift test", streaming: true).text == "run swift test")
        #expect(HomeMarkdown.render("an *idea", streaming: true).text == "an idea")
    }

    @Test func whileStreamingMarkersThatOpenNoWordStayAsWritten() {
        #expect(HomeMarkdown.render("2 * 3", streaming: true).text == "2 * 3")
        #expect(HomeMarkdown.render("5*3", streaming: true).text == "5*3")
        #expect(HomeMarkdown.render("snake_case_name", streaming: true).text == "snake_case_name")
        #expect(HomeMarkdown.render("ends with **", streaming: true).text == "ends with **")
        #expect(HomeMarkdown.render("a **b\nc", streaming: true).text == "a **b\nc")
    }

    // MARK: A posted message (finished)

    @Test func aFinishedMessageKeepsAnUnclosedOpenerAsWritten() {
        #expect(HomeMarkdown.render("an *idea").text == "an *idea")
        #expect(HomeMarkdown.render("run `swift test").text == "run `swift test")
        #expect(HomeMarkdown.render("**Note").text == "**Note")
        #expect(HomeMarkdown.render("run tests in *Tests").text == "run tests in *Tests")
        #expect(HomeMarkdown.render("**Note").runs.isEmpty)
    }

    @Test func theClosedSpanIsTheSameEitherWay() {
        for streaming in [false, true] {
            let r = HomeMarkdown.render("the **focused** tests", streaming: streaming)
            #expect(r.text == "the focused tests")
            #expect(Self.styles(r) == ["4+7:bold"])
        }
    }

    /// The mapping: a posted agent message is rendered finished; the running reply as streaming.
    @Test func theMappingRendersOnlyTheRunningReplyAsStreaming() {
        #expect(HomeMapping.markdown("an *idea").text == "an *idea")
        #expect(HomeMapping.markdown("an *idea", streaming: true).text == "an idea")
    }

    // MARK: Split points (round 8): a running reply renders stably whatever arrives next

    /// The running reply as its bubble shows it after an update that ended at `text`.
    static func shown(_ text: String) -> (text: String, runs: [TextRun]) {
        HomeMarkdown.render(HomeMarkdown.stableStreamingText(text), streaming: true)
    }

    /// Every character prefix of the reply: what the bubble shows is a prefix of the posted reply's
    /// text and holds no raw marker.
    static func checkEverySplit(_ reply: String) {
        let final = HomeMarkdown.render(reply).text
        let chars = Array(reply)
        for n in 0...chars.count {
            let text = String(chars.prefix(n))
            let shown = Self.shown(text).text
            #expect(final.hasPrefix(shown), "split after \(n) chars: \"\(shown)\" is not a prefix of \"\(final)\"")
            #expect(!shown.contains("*") && !shown.contains("`") && !shown.contains("]("), "split after \(n) chars shows a raw marker: \"\(shown)\"")
        }
    }

    @Test func aSplitInsideBold() {
        Self.checkEverySplit("Run the **focused** tests now.")
        #expect(Self.shown("Run the **focused*").text == "Run the focused")
        #expect(Self.styles(Self.shown("Run the **focused*")) == ["8+7:bold"])
    }

    @Test func aSplitInsideACodeSpan() {
        Self.checkEverySplit("Then `swift build` and done.")
        #expect(Self.shown("Then `swift bu").text == "Then swift bu")
        #expect(Self.shown("Then `").text == "Then ")
    }

    @Test func aSplitInsideALink() {
        Self.checkEverySplit("See [the docs](https://example.com/a(b)) first.")
        #expect(Self.shown("See [the do").text == "See ")
        #expect(Self.shown("See [the docs](https://exa").text == "See ")
        #expect(Self.shown("See [the docs](https://example.com) ok").text == "See the docs ok")
        // Brackets that are not a link settle at their next character.
        #expect(Self.shown("index a[0] then").text == "index a[0] then")
    }

    @Test func aClosedSpanKeepsItsStyleWhileTheReplyGrows() {
        let r = Self.shown("the **focused** tests and mo")
        #expect(r.text == "the focused tests and mo")
        #expect(Self.styles(r) == ["4+7:bold"])
    }
}
