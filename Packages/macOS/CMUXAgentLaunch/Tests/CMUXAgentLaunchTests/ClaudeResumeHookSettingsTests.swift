import CMUXAgentLaunch
import Foundation
import Testing

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5427.
///
/// cmux injects Claude Code's hooks from the `Resources/bin/claude` wrapper,
/// which is first on `PATH` inside cmux terminals and re-injects the hook
/// `--settings` whenever it sees `--resume`. The captured launch executable,
/// however, is the *real* claude binary (`CMUX_AGENT_LAUNCH_EXECUTABLE`).
/// Resuming with that captured path directly bypassed the wrapper, so resumed
/// claude sessions silently lost SessionStart / Stop / Notification. The fix
/// routes the claude resume argv through the bare `claude` wrapper.
@Suite("Claude resume routes through the cmux wrapper")
struct ClaudeResumeHookSettingsTests {
    @Test("Resume uses the `claude` wrapper, not the captured real binary")
    func resumeRoutesThroughWrapper() throws {
        let argv = try #require(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "s",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude", "--model", "opus"]
            )
        )

        // The wrapper (bare `claude`) must be the executable so its --resume hook
        // injection fires; the captured real-binary path must not survive.
        #expect(argv.first == "claude")
        #expect(!argv.contains("/opt/homebrew/bin/claude"))
        #expect(argv == ["claude", "--resume", "s", "--model", "opus"])
    }

    @Test("A captured hook --settings is still stripped (the wrapper re-adds current hooks)")
    func staleHookSettingsStripped() throws {
        // Process-captured argv may still carry the inline hook --settings. It is
        // dropped; the wrapper re-applies cmux's current hooks at exec time.
        let argv = try #require(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "s",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: [
                    "/opt/homebrew/bin/claude",
                    "--model",
                    "opus",
                    "--settings",
                    "/tmp/cmux-claude-hook-x/settings.json"
                ]
            )
        )
        #expect(argv == ["claude", "--resume", "s", "--model", "opus"])
    }

    @Test("A non-hook --settings is preserved and still routes through the wrapper")
    func nonHookSettingsPreserved() {
        let argv = AgentResumeArgv().builtInKind(
            kind: "claude",
            sessionId: "s",
            executablePath: "/opt/homebrew/bin/claude",
            arguments: ["/opt/homebrew/bin/claude", "--settings", "/home/me/settings.json"]
        )
        #expect(argv == ["claude", "--resume", "s", "--settings", "/home/me/settings.json"])
    }

    @Test("Merged hook --settings keeps user keys when resuming")
    func mergedHookSettingsKeepsUserKeysOnResume() throws {
        let mergedSettings = #"{"effortLevel":"max","preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"cmux hooks claude session-start","timeout":10}]}]}}"#

        let argv = try #require(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "s",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude", "--settings", mergedSettings]
            )
        )

        let settingsIndex = try #require(argv.firstIndex(of: "--settings"))
        try #require(settingsIndex + 1 < argv.count)
        try assertUserSettingsJSON(argv[settingsIndex + 1])
    }

    @Test("Merged inline hook --settings keeps user keys when resuming")
    func mergedInlineHookSettingsKeepsUserKeysOnResume() throws {
        let mergedSettings = #"{"effortLevel":"max","preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"cmux hooks claude session-start","timeout":10}]}]}}"#

        let argv = try #require(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "s",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude", "--settings=\(mergedSettings)"]
            )
        )

        let prefix = "--settings="
        let settingsArgument = try #require(argv.first { $0.hasPrefix(prefix) })
        try assertUserSettingsJSON(String(settingsArgument.dropFirst(prefix.count)))
    }

    @Test("User JSON that only mentions hook text is preserved")
    func userJSONMentioningHookTextPreserved() {
        let userSettings = #"{"effortLevel":"max","note":"docs mention hooks claude"}"#

        let argv = AgentResumeArgv().builtInKind(
            kind: "claude",
            sessionId: "s",
            executablePath: "/opt/homebrew/bin/claude",
            arguments: ["/opt/homebrew/bin/claude", "--settings", userSettings]
        )

        #expect(argv == ["claude", "--resume", "s", "--settings", userSettings])
    }

    private func assertUserSettingsJSON(_ settingsJSON: String) throws {
        let settingsData = try #require(settingsJSON.data(using: .utf8))
        let settingsObject = try #require(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])

        #expect(settingsObject["effortLevel"] as? String == "max")
        #expect(!settingsObject.keys.contains("hooks"))
        #expect(!settingsObject.keys.contains("preferredNotifChannel"))
    }
}
