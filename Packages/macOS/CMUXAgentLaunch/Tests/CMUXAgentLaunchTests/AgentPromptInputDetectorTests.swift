import Testing
@testable import CMUXAgentLaunch

/// Fixtures mirror what Claude Code 2.1.283 and Codex 0.154.0 draw, captured
/// with `tmux capture-pane -e`: Claude's input row is `❯` + no-break space
/// with an inverse-video cursor cell; Codex's is a bold `›`, a space, and a
/// faint placeholder.
@Suite("Agent prompt input detector")
struct AgentPromptInputDetectorTests {
    private static let rule = String(repeating: "\u{2500}", count: 40)

    private func span(_ text: String, at column: Int = 0, faint: Bool = false) -> AgentPromptScreenSpan {
        AgentPromptScreenSpan(column: column, text: text, faint: faint)
    }

    private func claudeScreen(input: [[AgentPromptScreenSpan]], above: [[AgentPromptScreenSpan]] = []) -> [[AgentPromptScreenSpan]] {
        above + [[span(Self.rule)]] + input + [
            [span(Self.rule)],
            [span("  \u{23F5}\u{23F5} auto mode on (shift+tab to cycle)")],
        ]
    }

    @Test("An empty Claude prompt is empty")
    func claudeEmpty() {
        let screen = claudeScreen(input: [[span("\u{276F}\u{00A0}"), span(" ", at: 2)]])
        #expect(AgentPromptInputState(screenRows: screen) == .empty)
    }

    @Test("Text typed at the Claude prompt is a draft")
    func claudeDraft() {
        let screen = claudeScreen(input: [[span("\u{276F}\u{00A0}half typed"), span(" ", at: 12)]])
        #expect(AgentPromptInputState(screenRows: screen) == .draft("half typed"))
    }

    @Test("Text after the cursor still counts as a draft")
    func claudeTextAfterCursor() {
        let screen = claudeScreen(input: [[span("\u{276F}\u{00A0}"), span("p", at: 2), span("ed", at: 3)]])
        #expect(AgentPromptInputState(screenRows: screen) == .draft("ped"))
    }

    @Test("Past prompts in the transcript are not the input row")
    func claudeTranscriptPromptIgnored() {
        let screen = claudeScreen(
            input: [[span("\u{276F}\u{00A0}"), span(" ", at: 2)]],
            above: [[span("\u{276F} say hi in two words")], [span("\u{25CF} Hello there!")]]
        )
        #expect(AgentPromptInputState(screenRows: screen) == .empty)
    }

    @Test("A multi-line Claude draft is read up to the rule")
    func claudeMultiLineDraft() {
        let screen = claudeScreen(input: [
            [span("\u{276F}\u{00A0}first line")],
            [span("  second line")],
        ])
        #expect(AgentPromptInputState(screenRows: screen) == .draft("first line\n  second line"))
    }

    @Test("Faint suggestion text in the Claude prompt is not a draft")
    func claudeFaintSuggestion() {
        let screen = claudeScreen(input: [[span("\u{276F}\u{00A0}"), span(" ", at: 2), span("Try \"fix lint errors\"", at: 3, faint: true)]])
        #expect(AgentPromptInputState(screenRows: screen) == .empty)
    }

    @Test("A boxed Claude prompt ignores its border")
    func claudeBoxedPrompt() {
        let screen = [
            [span("\u{256D}" + Self.rule + "\u{256E}")],
            [span("\u{2502} \u{276F}\u{00A0}"), span(" ", at: 4), span("\u{2502}", at: 41)],
            [span("\u{2570}" + Self.rule + "\u{256F}")],
        ]
        #expect(AgentPromptInputState(screenRows: screen) == .empty)
    }

    @Test("The Codex placeholder is not a draft")
    func codexPlaceholder() {
        let screen = [
            [span("\u{2022} You have 3 usage limit resets available.")],
            [],
            [span("\u{203A}"), span(" ", at: 1), span("Ask Codex to do anything", at: 2, faint: true)],
            [],
            [span("  gpt-6-astra high \u{00B7} /tmp/drafttest")],
        ]
        #expect(AgentPromptInputState(screenRows: screen) == .empty)
    }

    @Test("Text typed at the Codex prompt is a draft")
    func codexDraft() {
        let screen = [
            [span("\u{203A}"), span(" half typed codex", at: 1)],
            [],
            [span("  gpt-6-astra high \u{00B7} /tmp/drafttest")],
        ]
        #expect(AgentPromptInputState(screenRows: screen) == .draft("half typed codex"))
    }

    @Test("Menus and confirmation dialogs are dialogs")
    func dialogs() {
        let claudeTrust = [
            [span(" Quick safety check: Is this a project you created or one you trust?")],
            [span(" \u{276F} No, exit")],
            [span("   Yes, I trust this folder")],
            [span(" Enter to confirm \u{00B7} Esc to cancel")],
        ]
        let codexTrust = [
            [span("\u{203A} 1. Review hooks")],
            [span("  2. Trust all and continue")],
            [span("  Press enter to confirm or esc to go back")],
        ]
        #expect(AgentPromptInputState(screenRows: claudeTrust) == .dialog)
        #expect(AgentPromptInputState(screenRows: codexTrust) == .dialog)
        #expect(AgentPromptInputState.dialog.blocksTyping)
    }

    @Test("A hint quoted in the transcript above the input row is not a dialog")
    func hintAboveInputRowIgnored() {
        let screen = claudeScreen(
            input: [[span("\u{276F}\u{00A0}"), span(" ", at: 2)]],
            above: [[span("\u{25CF} Run the installer, then press enter to confirm the defaults.")]]
        )
        #expect(AgentPromptInputState(screenRows: screen) == .empty)
    }

    @Test("A hint below the input row is a dialog")
    func hintBelowInputRow() {
        let screen = [
            [span("\u{203A} 1. Allow once")],
            [span("  2. Deny")],
            [span("  Press enter to confirm or esc to go back")],
        ]
        #expect(AgentPromptInputState(screenRows: screen) == .dialog)
    }

    @Test("A shell prompt is not an agent prompt")
    func shellIsUnknown() {
        let screen = [[span("leo@big-red ~ % ls")], [span("a b c")], [span("leo@big-red ~ % ")]]
        #expect(AgentPromptInputState(screenRows: screen) == .unknown)
        #expect(!AgentPromptInputState.unknown.blocksTyping)
        #expect(!AgentPromptInputState.empty.blocksTyping)
        #expect(AgentPromptInputState.draft("x").blocksTyping)
    }

    @Test("Spans can arrive out of column order")
    func unorderedSpans() {
        let screen = claudeScreen(input: [[span(" ", at: 6), span("\u{276F}\u{00A0}", at: 0), span("abcd", at: 2)]])
        #expect(AgentPromptInputState(screenRows: screen) == .draft("abcd"))
    }

    @Test("Submission snapshot identifies Claude and preserves a long wrapped draft")
    func submissionSnapshotClaude() {
        let screen = claudeScreen(input: [
            [span("\u{276F}\u{00A0}first line")],
            [span("  second line [Pasted text #1 +2 lines]")],
        ])
        let snapshot = AgentPromptSubmissionSnapshot(screenRows: screen)
        #expect(snapshot.agentKind == .claude)
        #expect(snapshot.state == .draft("first line\n  second line [Pasted text #1 +2 lines]"))
        #expect(!snapshot.busy)
        #expect(!snapshot.queued)
    }

    @Test("Busy Codex exposes queue state")
    func busyCodex() {
        let screen = [
            [span(" Working on your request... (esc to interrupt)")],
            [span("\u{203A}"), span(" ", at: 1), span("Ask Codex to do anything", at: 2, faint: true)],
            [span("  Tab to queue")],
        ]
        let snapshot = AgentPromptSubmissionSnapshot(screenRows: screen)
        #expect(snapshot.agentKind == .codex)
        #expect(snapshot.busy)
        #expect(!snapshot.queued)
    }

    @Test("Codex queued status is exposed separately from busy")
    func queuedCodex() {
        let screen = [
            [span(" Working on your request...")],
            [span("\u{203A} queued follow-up")],
            [span("Queued")],
        ]
        let snapshot = AgentPromptSubmissionSnapshot(screenRows: screen)
        #expect(snapshot.agentKind == .codex)
        #expect(snapshot.queued)
    }

    @Test("Slash command popup is visible and remains a dialog")
    func slashCommandPopup() {
        let screen = [
            [span("\u{276F}\u{00A0}/goal resume")],
            [span("  /goal resume    Resume a goal")],
            [span("  /help           Show help")],
            [span("  Enter to select \u{00B7} Esc to cancel")],
        ]
        let snapshot = AgentPromptSubmissionSnapshot(screenRows: screen)
        #expect(snapshot.agentKind == .claude)
        #expect(snapshot.slashCommandPopup)
        #expect(snapshot.state == .dialog)
    }

    @Test("Slash command suggestions above the composer are detected")
    func slashCommandPopupAbovePrompt() {
        let screen = [
            [span("  /goal resume    Resume a goal")],
            [span("  /help           Show help")],
            [span("\u{276F}\u{00A0}/goal resume")],
        ]
        let snapshot = AgentPromptSubmissionSnapshot(screenRows: screen)
        #expect(snapshot.slashCommandPopup)
        #expect(snapshot.state == .dialog)
    }

    @Test("Text-only screen detection is available for remote panes")
    func textOnlyScreen() {
        let snapshot = AgentPromptSubmissionSnapshot(screenText: "Working...\n› Ask Codex to do anything\n  Tab to queue")
        #expect(snapshot.agentKind == .codex)
        #expect(snapshot.busy)
    }
}
