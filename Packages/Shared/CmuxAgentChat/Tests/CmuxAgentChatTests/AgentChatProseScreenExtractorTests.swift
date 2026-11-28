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

    /// A Claude streaming viewport: prior tool block, the in-progress answer
    /// (introduced by the "⏺ " bullet and wrapped under a 2-space hanging indent,
    /// as the real TUI renders it), the spinner/status line, then the input box
    /// and the bottom mode bar (which carries "esc to interrupt" while working).
    private func claudeStreamingScreen(answer: [String]) -> [String] {
        var rows = [
            "❯ Reply with three short sentences about the color blue.",
            "",
            "⏺ Read(notes.md)",
            "  ⎿ Read 12 lines",
            "",
        ]
        for (offset, line) in answer.enumerated() {
            rows.append(offset == 0 ? "⏺ \(line)" : "  \(line)")
        }
        rows.append(contentsOf: [
            "",
            "✢ Forming… (4s · ↓ 21 tokens)",
            Self.rule,
            "❯ ",
            Self.rule,
            "  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← for agents",
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

    @Test("anchors on an esc-to-interrupt working line without a timer glyph")
    func anchorsOnInterruptHint() {
        // Codex renders the interrupt hint on the working line itself and does not
        // bullet its answer, so the bullet-less body above the hint is the answer.
        let rows = [
            "Streaming answer body line one.",
            "Streaming answer body line two.",
            "  Thinking… esc to interrupt",
            String(repeating: "─", count: 20),
            "❯ ",
        ]
        let result = extractor.extract(lines: rows, agentKind: .codex)
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
        // Bare form (no paren), as in the "running stop hooks… 0/3 · 3s" status.
        #expect(AgentChatProseScreenExtractor.containsElapsedTimer("running stop hooks… 0/3 · 3s · ↓ 56 tokens"))
        #expect(!AgentChatProseScreenExtractor.containsElapsedTimer("(no timer here)"))
        #expect(!AgentChatProseScreenExtractor.containsElapsedTimer("plain text"))
        // "0/3" alone is not a timer.
        #expect(!AgentChatProseScreenExtractor.containsElapsedTimer("progress 0/3 done"))
    }

    @Test("parenthesized-timer scanner rejects the bare Brewed-for summary")
    func parenthesizedTimer() {
        #expect(AgentChatProseScreenExtractor.containsParenthesizedTimer("✢ Forming… (9s)"))
        #expect(AgentChatProseScreenExtractor.containsParenthesizedTimer("(1m05s)"))
        // The post-turn summary has a bare timer, so it is not a live anchor.
        #expect(!AgentChatProseScreenExtractor.containsParenthesizedTimer("✻ Brewed for 3s"))
    }

    // MARK: - Real Claude Code 2.1.191 frames

    // The synthetic fixtures above missed two things the live TUI does: the
    // in-progress answer is itself prefixed with "⏺ ", and the bottom mode bar
    // carries "esc to interrupt" *while working* (below the input box). These
    // frames are captured verbatim from a live `claude` turn via the debug
    // socket's read-screen, then replayed so the extractor is pinned to the real
    // rendering, not an idealized one.

    private static let realModeBarWorking =
        "  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← for agents"
    private static let realModeBarSettled =
        "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"

    /// A faithful Claude Code 2.1.191 viewport: welcome box, the echoed (wrapped)
    /// prompt, the answer body, the spinner/timer line, then the input box and the
    /// bottom mode bar (which carries "esc to interrupt" only while `working`).
    private func realClaudeScreen(answerBody: [String], status: String, working: Bool) -> [String] {
        var rows = [
            "Last login: Thu Jun 25 20:40:07 on ttys099",
            "claude",
            "╭─── Claude Code v2.1.191 ──────────────────────────╮",
            "│                 Welcome back Aziz!                │",
            "╰───────────────────────────────────────────────────╯",
            "",
            "",
            "❯ Reply with exactly three short sentences about the color blue. No preamble, no lists, just",
            "  three sentences.",
            "  ",
        ]
        rows.append(contentsOf: answerBody)
        rows.append("")
        rows.append(status)
        rows.append("")
        rows.append(Self.rule)
        rows.append("❯ ")
        rows.append(Self.rule)
        rows.append(working ? Self.realModeBarWorking : Self.realModeBarSettled)
        return rows
    }

    @Test("real frame: mid-stream partial sentence is isolated, not the mode bar")
    func realPartialFrame() {
        // Frame 19: the answer is cut mid-sentence and the bottom mode bar shows
        // "esc to interrupt". Anchoring on that bar would yield chrome; the
        // extractor must anchor on the spinner/timer line above the answer.
        let rows = realClaudeScreen(
            answerBody: [
                "⏺ The sky owes its blue to sunlight scattering across the atmosphere. Blue is often linked to",
            ],
            status: "✻ Nebulizing… (3s · ↓ 1 tokens)",
            working: true
        )
        let result = extractor.extract(lines: rows, agentKind: .claude)
        #expect(result == "The sky owes its blue to sunlight scattering across the atmosphere. Blue is often linked to")
    }

    @Test("real frame: full answer captured while still running stop hooks")
    func realFullFrame() {
        // Frame 21: full three-sentence answer, status switched to the bare-timer
        // "running stop hooks… 0/3 · 3s · ↓ 56 tokens" form (no paren around 3s).
        let rows = realClaudeScreen(
            answerBody: [
                "⏺ The sky owes its blue to sunlight scattering across the atmosphere. Blue is often linked to",
                "  calm, depth, and quiet trust. From sapphires to deep oceans, it spans some of nature's most",
                "  striking sights.",
            ],
            status: "✻ Nebulizing… (running stop hooks… 0/3 · 3s · ↓ 56 tokens)",
            working: true
        )
        let result = extractor.extract(lines: rows, agentKind: .claude)
        // The 2-space hanging indent under "⏺ " is stripped so the wrapped lines
        // read as one flowing answer.
        #expect(result == """
        The sky owes its blue to sunlight scattering across the atmosphere. Blue is often linked to
        calm, depth, and quiet trust. From sapphires to deep oceans, it spans some of nature's most
        striking sights.
        """)
    }

    @Test("real frame: empty answer (only the ⏺ bullet) yields nil")
    func realEmptyAnswerFrame() {
        // Frame 17: the block bullet has rendered but no words yet.
        let rows = realClaudeScreen(
            answerBody: ["⏺ "],
            status: "✢ Nebulizing… (2s · ↓ 1 tokens)",
            working: true
        )
        #expect(extractor.extract(lines: rows, agentKind: .claude) == nil)
    }

    @Test("real frame: settled turn (Brewed for 3s summary) yields nil")
    func realSettledFrame() {
        // Frame 22: turn done. The spinner line is replaced by the "Brewed for 3s"
        // summary (bare timer, no throughput) and the mode bar drops "esc to
        // interrupt", so the extractor must report no active stream.
        let rows = realClaudeScreen(
            answerBody: [
                "⏺ The sky owes its blue to sunlight scattering across the atmosphere. Blue is often linked to",
                "  calm, depth, and quiet trust. From sapphires to deep oceans, it spans some of nature's most",
                "  striking sights.",
            ],
            status: "✻ Brewed for 3s",
            working: false
        )
        #expect(extractor.extract(lines: rows, agentKind: .claude) == nil)
    }

    @Test("a long answer is capped, never folding the whole screen")
    func capsAnswerLength() {
        let answer = (0..<400).map { "line \($0)" }
        // No boundary above the answer: only the cap stops collection. Use Codex,
        // whose answer is bullet-less, so the cap (not the answer-top) bounds it.
        var rows = answer
        rows.append("✢ Forming… (9s)")
        let result = extractor.extract(lines: rows, agentKind: .codex)
        let lineCount = result?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
        #expect(lineCount <= 200)
    }
}
