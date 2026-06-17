import CMUXAgentContinuation
import Testing

@Suite("CodexContinuationArguments")
struct CodexContinuationArgumentsTests {
    @Test("Preserves future boolean flags and yolo for resume")
    func preservesFutureBooleanFlagsAndYoloForResume() {
        let preserved = CodexContinuationArguments().preservedTail([
            "--yolo",
            "--future-runtime-flag",
            "--model",
            "gpt-5.4",
            "initial prompt must not replay",
        ])

        #expect(preserved == [
            "--yolo",
            "--future-runtime-flag",
            "--model",
            "gpt-5.4",
        ])
    }

    @Test("Preserves future equals-value flags")
    func preservesFutureEqualsValueFlags() {
        let preserved = CodexContinuationArguments().preservedTail([
            "--future-mode=fast",
            "--model",
            "gpt-5.4",
            "initial prompt must not replay",
        ])

        #expect(preserved == [
            "--future-mode=fast",
            "--model",
            "gpt-5.4",
        ])
    }

    @Test("Preserves unknown value flags before explicit fork command")
    func preservesUnknownValueFlagsBeforeExplicitForkCommand() {
        let preserved = CodexContinuationArguments().preservedForkTail([
            "--future-profile",
            "experimental",
            "fork",
            "019dad34-d218-7943-b81a-eddac5c87951",
            "--yolo",
            "fork prompt must not replay",
        ])

        #expect(preserved == [
            "--future-profile",
            "experimental",
            "--yolo",
        ])
    }

    @Test("Drops transient remotes, image prompts, and old session selectors")
    func dropsTransientArguments() {
        let preserved = CodexContinuationArguments().preservedForkTail([
            "--image",
            "/tmp/screenshot.png",
            "--remote",
            "ws://127.0.0.1:1",
            "--remote-auth-token-env=CODEX_TOKEN",
            "fork",
            "019dad34-d218-7943-b81a-eddac5c87951",
            "--model",
            "gpt-5.4",
            "fork prompt must not replay",
        ])

        #expect(preserved == [
            "--model",
            "gpt-5.4",
        ])
    }

    @Test("Rejects noninteractive commands")
    func rejectsNoninteractiveCommands() {
        #expect(CodexContinuationArguments().preservedTail(["exec", "fix this"]) == nil)
        #expect(CodexContinuationArguments().preservedTail(["review", "--base", "main"]) == nil)
    }
}
