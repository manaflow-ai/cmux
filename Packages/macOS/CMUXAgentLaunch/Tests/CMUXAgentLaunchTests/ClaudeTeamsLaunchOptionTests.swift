import CMUXAgentLaunch
import Testing

/// `claudeTeamsLaunchHasOption` gates the claude-teams trust-gate bypass (#6447),
/// so it must match how Claude itself treats `--dangerously-skip-permissions`:
/// honored even after a positional prompt, but NOT when the token lands in the
/// prompt (after `--`, after the `--tmux` prompt boundary, or in a value slot).
@Suite("Claude Teams launch option detection")
struct ClaudeTeamsLaunchOptionTests {
    private func hasDangerousSkip(_ args: [String]) -> Bool {
        AgentLaunchSanitizer.claudeTeamsLaunchHasOption("--dangerously-skip-permissions", args: args)
    }

    @Test("Detects the flag as a leading option")
    func detectsLeadingOption() {
        #expect(hasDangerousSkip(["--dangerously-skip-permissions", "make a demo team"]))
    }

    @Test("Detects the flag after the positional prompt (Claude honors it)")
    func detectsFlagAfterPrompt() {
        #expect(hasDangerousSkip(["make a demo team", "--dangerously-skip-permissions"]))
    }

    @Test("Detects the --flag=value form")
    func detectsEqualsForm() {
        #expect(hasDangerousSkip(["--dangerously-skip-permissions=true", "do it"]))
    }

    @Test("Does NOT treat a prompt token after a real --tmux prompt payload as an opt-in")
    func ignoresAfterTmuxBoundary() {
        #expect(!hasDangerousSkip(["--tmux", "explain --dangerously-skip-permissions and continue"]))
    }

    @Test("Keeps scanning past the --tmux launch mode (classic), so a later flag is detected")
    func detectsAfterTmuxMode() {
        #expect(hasDangerousSkip(["--tmux", "classic", "--dangerously-skip-permissions"]))
        #expect(hasDangerousSkip(["--tmux=classic", "--dangerously-skip-permissions"]))
        #expect(hasDangerousSkip(["--tmux", "classic", "make a demo", "--dangerously-skip-permissions"]))
    }

    @Test("Does NOT treat a token after -- as an opt-in")
    func ignoresAfterDoubleDash() {
        #expect(!hasDangerousSkip(["--", "--dangerously-skip-permissions"]))
    }

    @Test("Does NOT treat the flag consumed as another option's value as an opt-in")
    func ignoresValueSlot() {
        #expect(!hasDangerousSkip(["--model", "--dangerously-skip-permissions", "prompt"]))
        // File-option values (paths) are not options either.
        #expect(!hasDangerousSkip(["--append-system-prompt-file", "--dangerously-skip-permissions"]))
        #expect(!hasDangerousSkip(["--system-prompt-file", "--dangerously-skip-permissions", "prompt"]))
    }

    @Test("Returns false when the flag is absent")
    func absentFlag() {
        #expect(!hasDangerousSkip(["--model", "sonnet", "make a demo team"]))
        #expect(!hasDangerousSkip([]))
    }
}
