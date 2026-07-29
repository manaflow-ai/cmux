import CMUXAgentLaunch
import Testing

/// Claude's permission-affecting launch flags are booleans (`--dangerously-skip-permissions`,
/// `--verbose`, …). The sanitizer must treat them as exactly one token wide: when it instead
/// infers a value for them, a one-word prompt positional that follows gets promoted to the
/// flag's "value" and is replayed verbatim on every resume/fork of the session.
/// https://github.com/manaflow-ai/cmux/issues/8066
@Suite("Claude boolean launch flags")
struct ClaudeBooleanLaunchFlagTests {
    @Test("Bypass flag does not swallow a one-word prompt bounded by a later flag")
    func bypassFlagDoesNotSwallowBoundedOneWordPrompt() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["claude", "--dangerously-skip-permissions", "build", "--model", "opus"],
                launcher: "claude",
                fallbackKind: "claude"
            ) == ["claude", "--dangerously-skip-permissions", "--model", "opus"]
        )
    }

    @Test("Bypass flag does not swallow a trailing comma-containing prompt word")
    func bypassFlagDoesNotSwallowTrailingCommaPromptWord() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["claude", "--dangerously-skip-permissions", "fix,polish"],
                launcher: "claude",
                fallbackKind: "claude"
            ) == ["claude", "--dangerously-skip-permissions"]
        )
    }

    @Test("Verbose flag does not swallow a one-word prompt bounded by a later flag")
    func verboseFlagDoesNotSwallowBoundedOneWordPrompt() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["claude", "--verbose", "lint", "--model", "opus"],
                launcher: "claude",
                fallbackKind: "claude"
            ) == ["claude", "--verbose", "--model", "opus"]
        )
    }

    @Test("Resume argv keeps bypass without replaying a one-word prompt")
    func resumeArgvKeepsBypassWithoutReplayingOneWordPrompt() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--dangerously-skip-permissions", "ship", "--model", "opus"]
            ) == ["claude", "--resume", "SID", "--dangerously-skip-permissions", "--model", "opus"]
        )
    }

    @Test("Fork argv keeps boolean flags without replaying a one-word prompt")
    func forkArgvKeepsBooleanFlagsWithoutReplayingOneWordPrompt() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--verbose", "ship", "--model", "opus"]
            ) == ["claude", "--resume", "SID", "--fork-session", "--verbose", "--model", "opus"]
        )
    }

    // MARK: - Guards that must keep passing

    @Test("Bare bypass flag is preserved through resume argv preservation")
    func bareBypassFlagIsPreserved() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--dangerously-skip-permissions"]
            ) == ["claude", "--resume", "SID", "--dangerously-skip-permissions"]
        )
    }

    @Test("Multi-word prompt after bypass flag stays dropped")
    func multiWordPromptAfterBypassFlagStaysDropped() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--dangerously-skip-permissions", "fix the flaky test"]
            ) == ["claude", "--resume", "SID", "--dangerously-skip-permissions"]
        )
    }

    @Test("Teams prompt payload never promotes a flag-shaped token to an option")
    func teamsPromptPayloadNeverPromotesFlagShapedToken() {
        #expect(
            !AgentLaunchSanitizer.claudeTeamsLaunchHasOption(
                "--dangerously-skip-permissions",
                args: ["--tmux", "--dangerously-skip-permissions"]
            )
        )
        #expect(
            AgentLaunchSanitizer.claudeTeamsLaunchHasOption(
                "--dangerously-skip-permissions",
                args: ["--dangerously-skip-permissions", "--tmux", "please do the thing"]
            )
        )
    }
}
