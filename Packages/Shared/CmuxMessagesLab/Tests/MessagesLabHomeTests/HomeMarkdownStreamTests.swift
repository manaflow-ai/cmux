import Testing
@testable import MessagesLabHome

/// An agent's reply streams in a few words at a time: its last line may hold an opener whose closer
/// has not arrived yet. No raw marker is drawn there (HomeMarkdown, round 4 capture: `**focused`).
@Suite struct HomeMarkdownStreamTests {
    static func styles(_ r: (text: String, runs: [TextRun])) -> [String] {
        r.runs.map { "\($0.start)+\($0.length):\(($0.style ?? []).joined(separator: ","))" }
    }

    @Test func anUnclosedBoldOnTheLastLineStylesTheRest() {
        let r = HomeMarkdown.render("the **focused")
        #expect(r.text == "the focused")
        #expect(Self.styles(r) == ["4+7:bold"])
        let more = HomeMarkdown.render("the **focused tests")
        #expect(more.text == "the focused tests")
        #expect(Self.styles(more) == ["4+13:bold"])
    }

    @Test func theClosedSpanIsUnchanged() {
        let r = HomeMarkdown.render("the **focused** tests")
        #expect(r.text == "the focused tests")
        #expect(Self.styles(r) == ["4+7:bold"])
    }

    @Test func unclosedCodeAndItalicOnTheLastLine() {
        #expect(HomeMarkdown.render("run `swift test").text == "run swift test")
        #expect(HomeMarkdown.render("an *idea").text == "an idea")
    }

    @Test func markersThatOpenNoWordStayAsWritten() {
        #expect(HomeMarkdown.render("2 * 3").text == "2 * 3")
        #expect(HomeMarkdown.render("5*3").text == "5*3")
        #expect(HomeMarkdown.render("snake_case_name").text == "snake_case_name")
        #expect(HomeMarkdown.render("ends with **").text == "ends with **")
    }

    @Test func anUnclosedOpenerBeforeTheLastLineStaysAsWritten() {
        #expect(HomeMarkdown.render("a **b\nc").text == "a **b\nc")
    }
}
