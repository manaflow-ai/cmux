import Testing
@testable import CmuxTerminalCore

@Suite("Agent key hint detector")
struct AgentKeyHintDetectorTests {
    private func hints(_ line: String, _ agent: AgentKeyHintDetector.Agent = .claudeCode) -> [AgentKeyHint] {
        AgentKeyHintDetector(agent: agent).hints(in: line)
    }

    @Test func claudeCodeFooterHints() {
        let expand = "  ⎿  … +53 lines (ctrl+o to expand)"
        #expect(hints(expand) == [AgentKeyHint(keys: ["ctrl+o"], action: "expand", columns: 18..<34)])
        #expect(AgentKeyHintDetector(agent: .claudeCode).hint(in: expand, atColumn: 18)?.keys == ["ctrl+o"])
        #expect(AgentKeyHintDetector(agent: .claudeCode).hint(in: expand, atColumn: 33) != nil)
        #expect(AgentKeyHintDetector(agent: .claudeCode).hint(in: expand, atColumn: 17) == nil, "The ( is not part of the hint")
        #expect(AgentKeyHintDetector(agent: .claudeCode).hint(in: expand, atColumn: 34) == nil, "Nor the )")

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

    @Test func wideCharactersTakeTwoCells() {
        // 日本 is four cells, then a space and "(", so the hint starts at cell 6.
        #expect(hints("日本 (ctrl+o to expand)").first?.columns == 6..<22)
    }
}
