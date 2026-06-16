import CMUXAgentContinuation
import Testing

@Suite("CursorContinuationArguments")
struct CursorContinuationArgumentsTests {
    @Test("Drops old resume selectors, workspace selectors, auth, and original prompt")
    func dropsOldResumeWorkspaceAuthAndPrompt() {
        let preserved = CursorContinuationArguments().preservedTail([
            "agent",
            "--model",
            "gpt-5.4",
            "--resume",
            "old-chat",
            "--workspace",
            "/tmp/old repo",
            "-H",
            "Authorization: Bearer secret",
            "--sandbox",
            "enabled",
            "initial prompt should not replay",
        ])

        #expect(preserved == [
            "--model",
            "gpt-5.4",
            "--sandbox",
            "enabled",
        ])
    }

    @Test("Preserves future Cursor flags before explicit resume command")
    func preservesFutureFlagsBeforeExplicitResumeCommand() {
        let preserved = CursorContinuationArguments().preservedTail([
            "--future-mode",
            "sticky",
            "--future-bool",
            "resume",
            "cursor-chat-123",
            "--model",
            "gpt-5.4",
        ])

        #expect(preserved == [
            "--future-mode",
            "sticky",
            "--future-bool",
            "--model",
            "gpt-5.4",
        ])
    }

    @Test("Rejects noninteractive Cursor launches")
    func rejectsNoninteractiveLaunches() {
        #expect(CursorContinuationArguments().preservedTail(["--print", "fix this"]) == nil)
        #expect(CursorContinuationArguments().preservedTail(["login"]) == nil)
    }
}
