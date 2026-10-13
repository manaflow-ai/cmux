import Testing
@testable import CmuxStatusBar

@Suite("Status bar line parsing")
struct StatusBarRunTests {
    @Test func plainTextIsOneUnstyledRun() {
        #expect(StatusBarRun.parse("5h 52%") == [StatusBarRun(text: "5h 52%")])
    }

    @Test func truecolorAndResetSplitRuns() {
        let runs = StatusBarRun.parse("\u{1b}[38;2;250;179;135mClaude\u{1b}[0m 52%")
        #expect(runs == [
            StatusBarRun(text: "Claude", color: .rgb(250, 179, 135)),
            StatusBarRun(text: " 52%"),
        ])
    }

    @Test func boldDimAndPaletteColors() {
        let runs = StatusBarRun.parse("\u{1b}[1;31mhot\u{1b}[22;2;94mcold")
        #expect(runs == [
            StatusBarRun(text: "hot", color: .palette(1), bold: true),
            StatusBarRun(text: "cold", color: .palette(12), dim: true),
        ])
    }

    /// OSC 8 may end with ESC \ or BEL, and an SGR reset inside the link must
    /// not close it.
    @Test func hyperlinksSurviveResetsAndBothTerminators() {
        let line = "\u{1b}]8;;cmux-action:codex\u{1b}\\\u{1b}[34mCodex\u{1b}[0m!\u{1b}]8;;\u{07} rest"
        #expect(StatusBarRun.parse(line) == [
            StatusBarRun(text: "Codex", color: .palette(4), link: "cmux-action:codex"),
            StatusBarRun(text: "!", link: "cmux-action:codex"),
            StatusBarRun(text: " rest"),
        ])
    }

    @Test func linkTargetKeepsSemicolonsAndParameters() {
        let runs = StatusBarRun.parse("\u{1b}]8;id=a;https://example.com/a;b\u{1b}\\x\u{1b}]8;;\u{1b}\\")
        #expect(runs == [StatusBarRun(text: "x", link: "https://example.com/a;b")])
    }

    @Test func otherEscapesAndControlCharactersAreDropped() {
        let runs = StatusBarRun.parse("\u{1b}[2K\u{1b}]0;title\u{07}a\u{1b}[48;2;1;2;3mb\u{08}\u{1b}=c")
        #expect(runs == [StatusBarRun(text: "abc")])
    }

    @Test func truncatedSequencesDoNotCrash() {
        #expect(StatusBarRun.parse("ok\u{1b}[38;2;1") == [StatusBarRun(text: "ok")])
        #expect(StatusBarRun.parse("ok\u{1b}") == [StatusBarRun(text: "ok")])
        #expect(StatusBarRun.parse("\u{1b}]8;;https://x") == [])
    }

    @Test func neighborsWithTheSameLinkShareOneSegment() {
        let runs = StatusBarRun.parse("a\u{1b}]8;;x\u{07}\u{1b}[1mb\u{1b}[0mc\u{1b}]8;;\u{07}d")
        #expect(StatusBarSegment.segments(of: runs) == [
            StatusBarSegment(link: nil, runs: [StatusBarRun(text: "a")]),
            StatusBarSegment(link: "x", runs: [
                StatusBarRun(text: "b", bold: true, link: "x"),
                StatusBarRun(text: "c", link: "x"),
            ]),
            StatusBarSegment(link: nil, runs: [StatusBarRun(text: "d")]),
        ])
    }
}
