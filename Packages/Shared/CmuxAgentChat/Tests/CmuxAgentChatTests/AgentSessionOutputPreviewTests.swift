import Testing
@testable import CmuxAgentChat

@Suite("Agent session output previews")
struct AgentSessionOutputPreviewTests {
    private let preview = AgentSessionOutputPreview()

    @Test("Claude Code chrome is removed while prose remains")
    func claudeCodeChrome() {
        let text = """
        ╭─ Claude Code ─╮
        │ ✳ Thinking... │
        Here is the fix.
        esc to interrupt
        ❯
        """
        #expect(preview.cleaned(text) == "Here is the fix.")
    }

    @Test("Codex chrome is removed while multiple output lines remain")
    func codexChrome() {
        let text = """
        ┌─ Codex ─┐
        ⠋ Working...
        ⏺ Changed the session projection.
        Tests pass.
        ? for shortcuts
        ›
        """
        #expect(preview.tail(text, lines: 2) == "Changed the session projection.\nTests pass.")
    }
}
