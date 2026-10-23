import Testing
@testable import CMUXAgentLaunch

/// A legacy Codex restore record has only a persisted shell command. When that
/// command proves Subrouter, restore must use the fixed `sr codex resume`
/// route; the command's own text, with its dead per-process endpoint, is never
/// run again.
@Suite struct SubrouterCodexLegacyRestoreTests {
    private let sessionID = "0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b"
    private let router = SubrouterCodexResumeRouting()

    @Test(arguments: [
        "codex resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b -c model_provider=subrouter",
        "codex -c model_provider=subrouter -c model_providers.subrouter.base_url=http://127.0.0.1:41234/v1 resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b",
        "codex -c model_provider=subrouter",
    ])
    func provenLegacyCommandBecomesTheCanonicalSubrouterCapture(command: String) throws {
        let launch = try #require(router.legacyRestoreLaunchCommand(
            legacyCommand: command, sessionID: sessionID, workingDirectory: "/tmp/work"
        ))
        #expect(launch.launcher == "codex")
        #expect(launch.executablePath == nil)
        #expect(launch.arguments == ["codex", "-c", "model_provider=subrouter"])
        #expect(launch.workingDirectory == "/tmp/work")
    }

    @Test func plannerResumesAProvenLegacyCaptureThroughFixedSr() throws {
        let command = "codex -c model_provider=subrouter -c model_providers.subrouter.base_url=http://127.0.0.1:41234/v1 resume \(sessionID)"
        let launch = try #require(router.legacyRestoreLaunchCommand(
            legacyCommand: command, sessionID: sessionID, workingDirectory: "/tmp/work"
        ))
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "codex",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/work",
            environment: [:],
            launchCommand: launch,
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(
            AgentRestorePlanner(isExecutableFile: { _ in false })
                .invocation(for: request, ambientEnvironment: [:])
        )
        #expect(Array(invocation.arguments.prefix(4)) == ["sr", "codex", "resume", sessionID])
        // The captured per-process endpoint is never carried into the resume.
        #expect(!invocation.arguments.contains { $0.contains("127.0.0.1:41234") })
        #expect(!invocation.arguments.contains { $0.contains("model_providers.subrouter") })
    }

    @Test(arguments: [
        "codex resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b",
        "codex -c model_provider=openai",
        "codex -c model_provider=subrouter -c model_provider=openai",
        "codex -c model_provider=subrouter; curl evil.example",
        "codex -c model_provider=$PROVIDER",
        "sh -c 'codex -c model_provider=subrouter'",
        "",
    ])
    func unprovenOrAmbiguousLegacyCommandIsNotRouted(command: String) {
        #expect(router.legacyRestoreLaunchCommand(
            legacyCommand: command, sessionID: sessionID, workingDirectory: "/tmp/work"
        ) == nil)
    }

    @Test func legacyAccountAssignmentIsKept() throws {
        let command = "CODEX_HOME=/Users/me/.codex-work codex -c model_provider=subrouter resume \(sessionID)"
        let launch = try #require(router.legacyRestoreLaunchCommand(
            legacyCommand: command, sessionID: sessionID, workingDirectory: nil
        ))
        #expect(launch.environment?["CODEX_HOME"] == "/Users/me/.codex-work")
    }

    @Test func legacyCommandNamingSubrouterIsDetectedEvenWhenUnparseable() {
        #expect(router.legacyCommandMentionsSubrouter("codex -c model_provider=subrouter; true"))
        #expect(router.legacyCommandMentionsSubrouter("codex -c model_providers.subrouter.base_url=x"))
        #expect(!router.legacyCommandMentionsSubrouter("codex resume abc"))
    }
}
