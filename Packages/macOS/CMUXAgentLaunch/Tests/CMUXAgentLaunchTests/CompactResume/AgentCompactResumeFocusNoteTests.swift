import Testing
@testable import CMUXAgentLaunch

@Suite("Compact and resume focus note")
struct AgentCompactResumeFocusNoteTests {
    @Test func namesTheLastRealPromptOnOneLine() {
        let note = AgentCompactResumeFocusNote(recentPrompts: [
            "an older prompt",
            "fix the flaky\n  sidebar test\tplease",
            "/review 15284",
            "Continue where you left off. Current task: an older prompt",
        ])
        #expect(note.text == "Keep the current task: fix the flaky sidebar test please; keep file paths, decisions and open TODOs.")
        #expect(note.taskLine == "Current task: fix the flaky sidebar test please")
        #expect(!note.text.contains("\n"))
    }

    @Test func longPromptsAreClipped() throws {
        let note = AgentCompactResumeFocusNote(recentPrompts: [String(repeating: "word ", count: 200)])
        let task = try #require(note.taskLine)
        #expect(task.hasSuffix("…"))
        #expect(note.text.count <= AgentCompactResumeFocusNote.textLimit)
    }

    @Test func customFocusReplacesTheGeneratedNote() {
        let note = AgentCompactResumeFocusNote(recentPrompts: ["fix it"], customFocus: "  keep the\nmigration plan ")
        #expect(note.text == "keep the migration plan")
        #expect(note.taskLine == "keep the migration plan")
    }

    @Test func noPromptsFallsBackToAGenericNote() {
        let note = AgentCompactResumeFocusNote(recentPrompts: ["/compact", "  "], customFocus: " ")
        #expect(note.text == "Keep the task in progress, file paths, decisions and open TODOs.")
        #expect(note.taskLine == nil)
    }

    @Test func dialectsBuildTheirCommands() {
        let note = AgentCompactResumeFocusNote(recentPrompts: ["fix it"])
        #expect(AgentCompactResumeDialect.claudeCode.compactCommand(focus: note) == "/compact \(note.text)")
        #expect(AgentCompactResumeDialect.codex.compactCommand(focus: note) == "/compact", "Codex's /compact takes no focus")
        #expect(AgentCompactResumeDialect.codex.resumePrompt(focus: note) == "Continue where you left off. Current task: fix it")
        let generic = AgentCompactResumeFocusNote(recentPrompts: [])
        #expect(AgentCompactResumeDialect.claudeCode.resumePrompt(focus: generic) == "Continue where you left off.")
    }
}
