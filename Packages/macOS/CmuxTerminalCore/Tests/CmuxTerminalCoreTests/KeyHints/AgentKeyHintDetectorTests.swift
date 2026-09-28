import Testing
@testable import CmuxTerminalCore

@Suite("Agent key hint detector")
struct AgentKeyHintDetectorTests {
    /// Hints on a line in the agent's live region, where every key counts.
    private func hints(_ line: String, _ agent: AgentKeyHintDetector.Agent = .claudeCode) -> [AgentKeyHint] {
        AgentKeyHintDetector(agent: agent).hints(in: line, inLiveRegion: true)
    }

    /// Hints on a line above the live region: transcript or prose.
    private func historyHints(_ line: String, _ agent: AgentKeyHintDetector.Agent = .claudeCode) -> [AgentKeyHint] {
        AgentKeyHintDetector(agent: agent).hints(in: line, inLiveRegion: false)
    }

    @Test func claudeCodeFooterHints() {
        let expand = "  ⎿  … +53 lines (ctrl+o to expand)"
        #expect(hints(expand) == [AgentKeyHint(keys: ["ctrl+o"], action: "expand", columns: 18..<34)])
        #expect(AgentKeyHintDetector(agent: .claudeCode).hint(in: expand, atColumn: 18, inLiveRegion: false)?.keys == ["ctrl+o"])
        #expect(AgentKeyHintDetector(agent: .claudeCode).hint(in: expand, atColumn: 33, inLiveRegion: false) != nil)
        #expect(AgentKeyHintDetector(agent: .claudeCode).hint(in: expand, atColumn: 17, inLiveRegion: false) == nil, "The ( is not part of the hint")
        #expect(AgentKeyHintDetector(agent: .claudeCode).hint(in: expand, atColumn: 34, inLiveRegion: false) == nil, "Nor the )")

        #expect(hints("✻ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)").map(\.keys) == [["escape"]])
        #expect(hints("  ⏵⏵ accept edits on (shift+tab to cycle)").map(\.keys) == [["shift+tab"]])
        #expect(hints("  ctrl+b ctrl+b to run in background").map(\.keys) == [["ctrl+b", "ctrl+b"]])
        #expect(hints("  ctrl+b ctrl+b to run in background").first?.action == "run in background")
        let pair = hints("  Esc to cancel · Tab to amend")
        #expect(pair.map(\.keys) == [["escape"], ["tab"]])
        #expect(pair.map(\.action) == ["cancel", "amend"])
        #expect(hints("  ↓ to manage").map(\.keys) == [["down"]])
        #expect(hints("  ? for shortcuts").map(\.keys) == [["?"]])
        #expect(hints("  ⌃O to expand").map(\.keys) == [["ctrl+o"]])
    }

    @Test func codexAndOpenCodeHints() {
        #expect(hints("  Esc to interrupt   tab to queue message", .codex).map(\.action) == ["interrupt", "queue message"])
        #expect(hints("esc interrupt", .openCode).map(\.keys) == [["escape"]])
        #expect(hints("esc interrupt", .claudeCode).isEmpty, "Only OpenCode prints hints without 'to'")
        #expect(hints("esc banana", .openCode).isEmpty)
    }

    @Test func quitAndSignalChordsAreNeverClickable() {
        #expect(hints("Press ctrl+c again to exit").isEmpty)
        #expect(hints("  ctrl+d to exit").isEmpty)
        #expect(hints("  ctrl+z to suspend").isEmpty)
    }

    @Test(arguments: [
        "Ctrl+Shift+C to copy", "ctrl+alt+c to cancel", "ctrl+shift+z to redo", "ctrl+shift+d to detach",
        "ctrl+alt+\\ to quit", "⌃⇧C to copy", "alt+ctrl+z to undo",
    ])
    func signalChordsWithExtraModifiersAreNeverClickable(line: String) {
        // Ghostty still sends 0x03, 0x04, 0x1a or 0x1c for these.
        #expect(hints(line).isEmpty, "\(line)")
    }

    @Test func returnIsNotAKeyWord() {
        #expect(hints("then return to continue the loop").isEmpty)
    }

    @Test func proseIsNotAHint() {
        for line in ["Everything is up to date.", "Run the end to end tests.", "go to the store",
                     "map a to b", "from 1 to 2", "Press enter to the void", "Tab to the left"] {
            #expect(hints(line).isEmpty, "\(line)")
        }
        #expect(hints("Press enter to continue").map(\.keys) == [["enter"]])
    }

    @Test(arguments: [
        "Scroll down to view the full log", "then return to continue the loop",
        "we go up to open the file", "press home to go back",
    ])
    func proseNamingKeysIsInertOutsideTheLiveRegion(line: String) {
        #expect(historyHints(line).isEmpty, "\(line)")
    }

    @Test func bareKeysCountOnlyInTheLiveRegion() {
        for line in ["✻ Thinking… (esc to interrupt)", "  Esc to cancel · Tab to amend", "  ↓ to manage",
                     "  ? for shortcuts", "  ⏵⏵ accept edits on (shift+tab to cycle)"] {
            #expect(historyHints(line).isEmpty, "\(line)")
            #expect(!hints(line).isEmpty, "\(line)")
        }
        // Ctrl and Alt chords name one binding, so they count in the transcript too.
        #expect(historyHints("  ⎿  … +53 lines (ctrl+o to expand)").map(\.keys) == [["ctrl+o"]])
        #expect(historyHints("  ctrl+b ctrl+b to run in background").map(\.keys) == [["ctrl+b", "ctrl+b"]])
        #expect(historyHints("alt+m to switch mode").map(\.keys) == [["alt+m"]])
    }

    @Test func aWrappedRowIsReadOnItsOwn() {
        // The second row of a soft-wrapped footer: the hint's cells count
        // from the start of that row, not of the logical line.
        #expect(historyHints("lines (ctrl+o to expand)").first?.columns == 7..<23)
    }

    @Test func wideCharactersTakeTwoCells() {
        // 日本 is four cells, then a space and "(", so the hint starts at cell 6.
        #expect(hints("日本 (ctrl+o to expand)").first?.columns == 6..<22)
    }
}
