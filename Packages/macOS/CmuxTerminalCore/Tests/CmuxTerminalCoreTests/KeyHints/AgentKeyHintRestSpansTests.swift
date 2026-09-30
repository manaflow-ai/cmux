import Testing
@testable import CmuxTerminalCore

@Suite("Agent key hint rest spans")
struct AgentKeyHintRestSpansTests {
    @Test func marksOnlyLiveRowsAndCodexCommands() {
        let rows: [(row: Int, text: String)] = [
            (0, "ctrl+o to expand"),
            (3, "esc to interrupt"),
            (9, "+ Show details"),
        ]
        let spans = agentKeyHintRestSpans(
            rows: rows,
            agent: .codex,
            viewportAtBottom: true,
            cursorRow: 9,
            style: .dotted
        )
        #expect(spans.map(\.row) == [3, 9])
        #expect(spans.allSatisfy { $0.style == .dotted })
    }

    @Test func scrolledBackProducesNoSpansAndStylesShareGeometry() {
        let rows = [(row: 8, text: "esc to interrupt")]
        #expect(agentKeyHintRestSpans(rows: rows, agent: .codex, viewportAtBottom: false, cursorRow: 8, style: .dotted).isEmpty)
        let dotted = agentKeyHintRestSpans(rows: rows, agent: .codex, viewportAtBottom: true, cursorRow: 8, style: .dotted)
        let underline = agentKeyHintRestSpans(rows: rows, agent: .codex, viewportAtBottom: true, cursorRow: 8, style: .underline)
        #expect(dotted.map { ($0.row, $0.columns) } == underline.map { ($0.row, $0.columns) })
        #expect(dotted.map(\.style) != underline.map(\.style))
        #expect(agentKeyHintRestSpans(rows: rows, agent: .codex, viewportAtBottom: true, cursorRow: 8, style: .none).isEmpty)
    }
}
