import Testing
@testable import CmuxAgentChat

@Suite("Agent session output previews")
struct AgentSessionOutputPreviewTests {
    @Test("Claude Code chrome is removed while prose remains")
    func claudeCodeChrome() {
        let text = """
        ╭─ Claude Code ─╮
        │ ✳ Thinking... │
        Here is the fix.
        esc to interrupt
        ❯
        """
        #expect(AgentSessionOutputPreview.cleaned(text) == "Here is the fix.")
    }

    @Test("Codex chrome is removed while multiple output lines remain")
    func codexChrome() {
        let text = """
        ┌─ Codex ─┐
        ⠋ Working...
        Changed the session projection.
        Tests pass.
        ? for shortcuts
        >
        """
        #expect(AgentSessionOutputPreview.tail(text, lines: 2) == "Changed the session projection.\nTests pass.")
    }
}
