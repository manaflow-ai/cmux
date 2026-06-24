import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixtures mirror the rendered viewport of Claude Code 2.1 / Codex while a turn
/// streams: an answer block above a working/status line, with the input box and
/// footer below it. The extractor must isolate the answer and return `nil` when
/// no turn is actively streaming.
@Suite("AgentChatProseScreenExtractor")
struct AgentChatProseScreenExtractorTests {
    private let extractor = AgentChatProseScreenExtractor()

    private static let rule = String(repeating: "─", count: 48)

    /// A Claude streaming viewport: prior tool block, the in-progress answer,
    /// the spinner/status line, then the input box and footer chrome.
    private func claudeStreamingScreen(answer: [String]) -> [String] {
        var rows = [
            "> Reply with three short sentences about the color blue.",
            "",
            "⏺ Read(notes.md)",
            "  ⎿ Read 12 lines",
            "",
        ]
        rows.append(contentsOf: answer)
        rows.append(contentsOf: [
            "",
            "✢ Forming… (4s · ↓ 21 tokens)",
            Self.rule,
            "❯ ",
            Self.rule,
            "⏵⏵ auto mode (shift+tab to cycle)",
        ])
        return rows
    }

    @Test("isolates the in-progress answer above the status line")
    func isolatesAnswer() {
        let answer = [
            "The sky owes its blue to how air scatters sunlight.",
            "Blue is often linked with calm, depth, and quiet focus.",
            "From sapphires to deep ocean water, it is everywhere.",
        ]
        let result = extractor.extract(lines: claudeStreamingScreen(answer: answer), agentKind: .claude)
        #expect(result == answer.joined(separator: "\n"))
    }

    @Test("keeps paragraph breaks but drops padding blank runs")
    func keepsParagraphBreaks() {
        let answer = [
            "First paragraph.",
            "",
            "",
            "Second paragraph.",
        ]
        let result = extractor.extract(lines: claudeStreamingScreen(answer: answer), agentKind: .claude)
        #expect(result == "First paragraph.\n\nSecond paragraph.")
    }

    @Test("returns nil when no turn is actively streaming")
    func nilWhenSettled() {
        // No status line: the turn has ended and the answer is committed.
        let rows = [
            "⏺ The sky is blue because of Rayleigh scattering.",
            "",
            Self.rule,
            "❯ ",
            Self.rule,
            "⏵⏵ auto mode",
        ]
        #expect(extractor.extract(lines: rows, agentKind: .claude) == nil)
    }

    @Test("returns nil when the status line has no answer above it")
    func nilWhenNoAnswer() {
        let rows = [
            "⏺ Read(notes.md)",
            "  ⎿ Read 12 lines",
            "✶ Thinking… (2s · esc to interrupt)",
            Self.rule,
            "❯ ",
        ]
        #expect(extractor.extract(lines: rows, agentKind: .claude) == nil)
    }

    @Test("anchors on an esc-to-interrupt status line without a timer glyph")
    func anchorsOnInterruptHint() {
        let rows = [
            "Streaming answer body line one.",
            "Streaming answer body line two.",
            "  Thinking… esc to interrupt",
            String(repeating: "─", count: 20),
            "❯ ",
        ]
        let result = extractor.extract(lines: rows, agentKind: .claude)
        #expect(result == "Streaming answer body line one.\nStreaming answer body line two.")
    }

    @Test("a Codex working screen isolates its answer")
    func codexScreen() {
        let rows = [
            "› summarize the file",
            "",
            "Here is the summary you asked for.",
            "It spans two lines of streaming prose.",
            "Working (3s • Esc to interrupt)",
            "▌",
        ]
        let result = extractor.extract(lines: rows, agentKind: .codex)
        #expect(result == "Here is the summary you asked for.\nIt spans two lines of streaming prose.")
    }

    @Test("elapsed-timer scanner matches seconds and minutes forms")
    func elapsedTimer() {
        #expect(AgentChatProseScreenExtractor.containsElapsedTimer("(4s"))
        #expect(AgentChatProseScreenExtractor.containsElapsedTimer("foo (12s · bar)"))
        #expect(AgentChatProseScreenExtractor.containsElapsedTimer("(1m05s)"))
        #expect(!AgentChatProseScreenExtractor.containsElapsedTimer("(no timer here)"))
        #expect(!AgentChatProseScreenExtractor.containsElapsedTimer("plain text"))
    }

    @Test("a long answer is capped, never folding the whole screen")
    func capsAnswerLength() {
        let answer = (0..<400).map { "line \($0)" }
        // No boundary above the answer: only the cap stops collection.
        var rows = answer
        rows.append("✢ Forming… (9s)")
        let result = extractor.extract(lines: rows, agentKind: .claude)
        let lineCount = result?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
        #expect(lineCount <= 200)
    }
}
