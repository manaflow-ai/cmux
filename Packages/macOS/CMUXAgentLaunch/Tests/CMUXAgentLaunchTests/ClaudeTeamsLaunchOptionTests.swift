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

    @Test("Recognizes canonical Claude management commands after safe options")
    func recognizesManagementCommands() {
        let classifier = AgentLaunchInvocationClassifier()
        for command in [
            "auth", "auto-mode", "doctor", "gateway", "install", "kill", "logs", "mcp",
            "plugin", "plugins", "project", "rm", "setup-token", "stop", "update", "upgrade",
        ] {
            #expect(classifier.claudeTeamsLaunchIsManagementCommand(args: [command]))
            #expect(classifier.claudeTeamsLaunchIsManagementCommand(args: ["--verbose", command]))
        }
        #expect(classifier.claudeTeamsLaunchIsManagementCommand(
            args: ["--tmux", "classic", "auth"]
        ))
        #expect(classifier.claudeTeamsLaunchIsManagementCommand(args: ["logs", "session-id"]))
        for subcommand in ["logs", "status", "stop", "uninstall"] {
            #expect(classifier.claudeTeamsLaunchIsManagementCommand(args: ["daemon", subcommand]))
        }
        #expect(classifier.claudeTeamsLaunchIsManagementCommand(
            args: ["daemon", "--json-path", "/tmp/daemon.json", "status"]
        ))
        #expect(classifier.claudeTeamsLaunchIsManagementCommand(args: ["agents", "--json"]))
        #expect(classifier.claudeTeamsLaunchIsManagementCommand(args: ["agents", "--all", "--json"]))
    }

    @Test("Does not promote command-shaped values or prompt payloads")
    func rejectsManagementCommandMasqueraders() {
        let classifier = AgentLaunchInvocationClassifier()
        let launches = [
            ["agents"],
            ["agents", "--all"],
            ["agents", "--json", "prompt"],
            ["--verbose", "agents"],
            ["daemon"],
            ["daemon", "run"],
            ["daemon", "--json-path", "run"],
            ["--model", "config"],
            ["--model", "logs"],
            ["--append-system-prompt", "doctor"],
            ["--tmux", "config"],
            ["--", "config"],
            ["please", "config"],
            ["--unknown-option", "config"],
            ["--debug", "auth", "start a team"],
            ["-d", "doctor", "start a team"],
            ["--continue", "config"],
            ["--remote-control", "session-name", "auth"],
            ["--resume", "doctor"],
            ["--worktree", "config"],
            ["api-key"],
            ["config"],
            ["rc"],
            ["remote-control"],
            ["import"],
            ["import", "codex", "--dry-run"],
            ["ultrareview"],
        ]
        for args in launches {
            #expect(!classifier.claudeTeamsLaunchIsManagementCommand(args: args))
        }
    }
}
