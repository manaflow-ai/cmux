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

    @Test("Claude resume strips a stale captured hook --settings in equals form")
    func claudeResumeStripsStaleEqualsFormHookSettings() throws {
        // Equals form of the captured (stale) hook --settings must be dropped,
        // and cmux's current hooks re-applied.
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

        let settings = try #require(settingsValue(in: argv))
        #expect(settings.contains("hooks claude session-start"))
        #expect(!argv.contains("--settings=/tmp/cmux-claude-hook-x/settings.json"))
        #expect(argv.contains("--model"))
        #expect(argv.contains("opus"))
    }

    @Test("Production shape: re-applies hooks even when captured argv was already sanitized")
    func reappliesHooksForAlreadySanitizedCapture() throws {
        // The real capture pipeline persists a sanitized launch command, so the
        // hook --settings is already gone by resume time. Hooks must still be
        // re-applied. https://github.com/manaflow-ai/cmux/issues/5427
        let argv = try #require(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "s",
                executablePath: nil,
                arguments: ["claude", "--model", "opus", "--permission-mode", "auto"]
            )
        )
        let settings = try #require(settingsValue(in: argv))
        #expect(settings.contains("hooks claude session-start"))
        #expect(settings.contains("hooks claude stop"))
        #expect(settings.contains("hooks claude notification"))
        #expect(argv == [
            "claude", "--resume", "s",
            "--settings", ClaudeHookSettings.settingsJSON,
            "--model", "opus", "--permission-mode", "auto"
        ])
    }

    @Test("A non-hook --settings is preserved alongside the re-applied hooks")
    func nonHookSettingsPreservedAlongsideHooks() {
        let argv = AgentResumeArgv().builtInKind(
            kind: "claude",
            sessionId: "s",
            executablePath: nil,
            arguments: ["claude", "--settings", "/home/me/settings.json"]
        )

        // The user's own settings survive, and cmux's hook --settings is applied
        // first (matching the fresh-launch wrapper order: hooks, then user args).
        #expect(argv == [
            "claude", "--resume", "s",
            "--settings", ClaudeHookSettings.settingsJSON,
            "--settings", "/home/me/settings.json"
        ])
    }
}
