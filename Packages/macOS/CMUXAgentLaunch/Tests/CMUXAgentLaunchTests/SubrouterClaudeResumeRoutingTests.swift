import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("SubrouterClaudeResumeRouting")
struct SubrouterClaudeResumeRoutingTests {
    private let sessionID = "0198f073-0a5b-7000-8000-000000000059"
    private let marker = "sr claude proxy --resume"
    private let router = SubrouterClaudeResumeRouting()

    private func provenEnvironment(_ marker: String) -> [String: String] {
        [
            SubrouterClaudeResumeRouting.environmentKey: marker,
            SubrouterClaudeResumeRouting.launchBoundEnvironmentKey: marker,
        ]
    }

    @Test(
        "Only the two exact launcher commands canonicalize",
        arguments: [
            ("sr claude proxy --resume", "sr claude proxy --resume"),
            ("  subrouter   claude\tproxy --resume ", "subrouter claude proxy --resume"),
            ("sr claude proxy --restore", nil),
            ("sr claude proxy --resume --account x", nil),
            ("sr claude proxy", nil),
            ("cx claude proxy --resume", nil),
            ("/usr/local/bin/sr claude proxy --resume", nil),
            ("sr claude proxy --resume;id", nil),
            ("", nil),
        ] as [(String, String?)]
    )
    func canonicalMarkerIsExact(raw: String, expected: String?) {
        #expect(router.canonicalMarker(raw) == expected)
    }

    @Test("The captured environment is the agreeing pair, or nothing")
    func capturedEnvironmentRequiresAgreeingPair() {
        #expect(router.capturedEnvironment(in: provenEnvironment(marker)) == provenEnvironment(marker))
        #expect(router.capturedEnvironment(in: [SubrouterClaudeResumeRouting.environmentKey: marker]).isEmpty)
        #expect(router.capturedEnvironment(in: [SubrouterClaudeResumeRouting.launchBoundEnvironmentKey: marker]).isEmpty)
        #expect(router.capturedEnvironment(in: [
            SubrouterClaudeResumeRouting.environmentKey: marker,
            SubrouterClaudeResumeRouting.launchBoundEnvironmentKey: "subrouter claude proxy --resume",
        ]).isEmpty)
        #expect(router.capturedEnvironment(in: nil).isEmpty)
    }

    @Test("Provenance is scoped to plain claude launches")
    func provenanceIsScopedToPlainClaudeLaunches() {
        #expect(router.provesRoutedLaunch(launcher: nil, environment: provenEnvironment(marker)))
        #expect(router.provesRoutedLaunch(launcher: " Claude ", environment: provenEnvironment(marker)))
        #expect(router.provesRoutedLaunch(launcher: "claudeTeams", environment: provenEnvironment(marker)) == false)
        #expect(router.provesRoutedLaunch(launcher: "codex", environment: provenEnvironment(marker)) == false)
        #expect(router.provesRoutedLaunch(launcher: nil, environment: [:]) == false)
        #expect(router.launcherExecutable(in: provenEnvironment("subrouter claude proxy --resume")) == "subrouter")
        #expect(router.launcherExecutable(in: [:]) == nil)
    }

    @Test("The resume argv is the marker, the session id, then the replay-safe claude options")
    func resumeArgumentsFollowTheMarker() {
        let privateSettings = "/var/folders/zz/T/subrouter-claude-settings-42/settings.json"
        let arguments = router.resumeArguments(
            launcher: nil,
            sessionID: sessionID,
            launchArguments: [
                "/opt/homebrew/bin/claude",
                "--settings", privateSettings,
                "--model", "opus",
                "--resume", "1111aaaa-0a5b-7000-8000-000000000001",
                "--settings", "~/my-settings.json",
                "--add-dir", "/tmp/extra",
            ],
            environment: provenEnvironment(marker)
        )

        #expect(
            arguments == [
                "sr", "claude", "proxy", "--resume", sessionID,
                "--model", "opus",
                "--settings", "~/my-settings.json",
                "--add-dir", "/tmp/extra",
            ],
            "\(String(describing: arguments))"
        )
    }

    @Test("An environment-only record still resumes through the launcher")
    func environmentOnlyRecordResumes() {
        #expect(
            router.resumeArguments(
                launcher: nil,
                sessionID: sessionID,
                launchArguments: [],
                environment: provenEnvironment(marker)
            ) == ["sr", "claude", "proxy", "--resume", sessionID]
        )
    }

    @Test("Private settings detection matches only Subrouter's per-launch directory")
    func privateSettingsPathDetection() {
        #expect(SubrouterClaudeResumeRouting.isPrivateSettingsPath("/tmp/subrouter-claude-settings-1/settings.json"))
        #expect(SubrouterClaudeResumeRouting.isPrivateSettingsPath(" /var/folders/T/subrouter-claude-settings-abc/settings.json "))
        #expect(SubrouterClaudeResumeRouting.isPrivateSettingsPath("/tmp/cmux-claude-settings.abc") == false)
        #expect(SubrouterClaudeResumeRouting.isPrivateSettingsPath("/tmp/subrouter-claude-settings-1/other.json") == false)
        #expect(SubrouterClaudeResumeRouting.isPrivateSettingsPath("~/.claude/settings.json") == false)
        #expect(SubrouterClaudeResumeRouting.isPrivateSettingsPath("{\"hooks\":{}}") == false)
    }

    @Test("Literal arguments after the option terminator are never touched")
    func optionTerminatorIsRespected() {
        let privateSettings = "/tmp/subrouter-claude-settings-1/settings.json"
        #expect(
            router.removingPrivateSettingsArguments(from: ["--", "--settings", privateSettings])
                == ["--", "--settings", privateSettings]
        )
        #expect(
            router.removingPrivateSettingsArguments(from: ["--settings=\(privateSettings)", "prompt"])
                == ["prompt"]
        )
    }
}
