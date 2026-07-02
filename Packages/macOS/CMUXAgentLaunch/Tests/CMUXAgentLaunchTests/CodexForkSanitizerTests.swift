import CMUXAgentLaunch
import Testing

@Suite("Codex fork sanitizer")
struct CodexForkSanitizerTests {
    @Test("Resume drops fork prompt tags but preserves later options")
    func resumeDropsForkPromptTagsButPreservesLaterOptions() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "codex",
                    "fork",
                    "019ef275-74e3-7777-9773-9dcb118ed5ad",
                    "tag-one",
                    "--sandbox",
                    "danger-full-access",
                ],
                launcher: "codex",
                fallbackKind: "codex"
            ) == ["codex", "--sandbox", "danger-full-access"]
        )
    }
}
