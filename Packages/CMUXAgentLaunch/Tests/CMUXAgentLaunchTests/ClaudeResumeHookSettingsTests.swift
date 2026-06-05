import CMUXAgentLaunch
import Testing

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5427.
///
/// A cmux-launched `claude` process always carries cmux's hook `--settings`
/// (injected by the `Resources/bin/claude` wrapper) so SessionStart / Stop /
/// Notification fire back into cmux. Native `claude --resume` captures the live
/// process argv, and the resume sanitizer intentionally strips that captured
/// hook `--settings` (it can be stale). The bug is that nothing re-applies
/// cmux's current hook settings, so resumed sessions silently lose every hook.
@Suite("Claude resume re-applies cmux hook settings")
struct ClaudeResumeHookSettingsTests {
    /// Pulls the value passed to the last `--settings` option in an argv.
    private func settingsValue(in argv: [String]) -> String? {
        guard let optionIndex = argv.lastIndex(of: "--settings"),
              optionIndex + 1 < argv.count else {
            return nil
        }
        return argv[optionIndex + 1]
    }

    @Test("Claude resume re-includes cmux's current hook --settings")
    func claudeResumeReinjectsHookSettings() throws {
        let argv = try #require(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "s",
                executablePath: nil,
                arguments: [
                    "claude",
                    "--model",
                    "opus",
                    "--settings",
                    "/tmp/cmux-claude-hook-x/settings.json"
                ]
            )
        )

        let settings = try #require(
            settingsValue(in: argv),
            "Claude resume argv must carry a --settings option re-applying cmux hooks"
        )

        // The re-applied settings must wire the lifecycle hooks back to the
        // cmux bridge subcommand (`cmux hooks claude <event>`), not just be
        // any --settings value.
        #expect(settings.contains("hooks claude session-start"))
        #expect(settings.contains("hooks claude stop"))
        #expect(settings.contains("hooks claude notification"))

        // The captured session selector still must not survive the resume.
        #expect(!argv.contains("/tmp/cmux-claude-hook-x/settings.json"))
        // Non-hook flags are preserved.
        #expect(argv.contains("--model"))
        #expect(argv.contains("opus"))
    }

    @Test("Claude resume re-applies hooks for the --settings=<value> equals form")
    func claudeResumeReinjectsHookSettingsEqualsForm() throws {
        let argv = try #require(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "s",
                executablePath: nil,
                arguments: [
                    "claude",
                    "--model",
                    "opus",
                    "--settings=/tmp/cmux-claude-hook-x/settings.json"
                ]
            )
        )

        let settings = try #require(
            settingsValue(in: argv),
            "Claude resume argv must carry a --settings option re-applying cmux hooks"
        )
        #expect(settings.contains("hooks claude session-start"))
        #expect(settings.contains("hooks claude stop"))
        #expect(settings.contains("hooks claude notification"))

        #expect(!argv.contains("--settings=/tmp/cmux-claude-hook-x/settings.json"))
        #expect(argv.contains("--model"))
        #expect(argv.contains("opus"))
    }

    @Test("A non-hook --settings is preserved and does not trigger re-injection")
    func nonHookSettingsPreservedWithoutInjection() {
        let argv = AgentResumeArgv().builtInKind(
            kind: "claude",
            sessionId: "s",
            executablePath: nil,
            arguments: [
                "claude",
                "--settings",
                "/home/me/settings.json"
            ]
        )

        // The user's own settings survive, and because the captured launch
        // never carried a cmux hook --settings, no hook settings are injected.
        #expect(argv == ["claude", "--resume", "s", "--settings", "/home/me/settings.json"])
    }
}
