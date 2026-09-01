import Testing
@testable import CMUXAgentLaunch

@Suite("Agent restore route classifier")
struct AgentRestoreRouteClassifierTests {
    @Test("classifies direct and routed Codex launches")
    func classifiesCodexRoutes() {
        let classifier = AgentRestoreRouteClassifier()

        #expect(classifier.route(for: request(
            kind: "codex",
            arguments: ["codex"]
        )) == .direct)
        #expect(classifier.route(for: request(
            kind: "codex",
            arguments: ["codex", "Explain openai_base_url=https://api.example.test"]
        )) == .direct)
        #expect(classifier.route(for: request(
            kind: "codex",
            arguments: ["codex", "-c", "model_provider=\"subrouter\""]
        )) == .pooled)
        #expect(classifier.route(for: request(
            kind: "codex",
            arguments: [
                "codex",
                "-c",
                "model_provider=\"subrouter\"",
                "-c",
                "model_providers.subrouter.http_headers={\"X-Subrouter-Account-ID\"=\"team-1\"}",
            ],
            environment: ["CODEX_HOME": "/captured/team-1"]
        )) == .pinned)
    }

    @Test("classifies direct and routed Claude launches")
    func classifiesClaudeRoutes() {
        let classifier = AgentRestoreRouteClassifier()

        #expect(classifier.route(for: request(
            kind: "claude",
            arguments: ["claude"]
        )) == .direct)
        #expect(classifier.route(for: request(
            kind: "claude",
            arguments: ["claude"],
            environment: ["ANTHROPIC_BASE_URL": "https://api.example.test"]
        )) == .direct)
        #expect(classifier.route(for: request(
            kind: "claude",
            arguments: ["claude"],
            environment: ["ANTHROPIC_BASE_URL": "http://subrouter.invalid"]
        )) == .pooled)
        #expect(classifier.route(for: request(
            kind: "claude",
            arguments: ["claude"],
            environment: ["ANTHROPIC_BASE_URL": "https://sr.cmux.com"]
        )) == .pooled)
        #expect(classifier.route(for: request(
            kind: "claude",
            arguments: ["claude"],
            environment: ["ANTHROPIC_BASE_URL": "https://staging.sr.cmux.com"]
        )) == .pooled)
        #expect(classifier.route(for: request(
            kind: "claude",
            arguments: ["claude"],
            environment: [
                "ANTHROPIC_BASE_URL": "http://subrouter.invalid",
                "CLAUDE_CONFIG_DIR": "/captured/team-claude",
            ]
        )) == .pinned)
    }

    @Test("explicit direct mode stays direct despite captured routing state")
    func directModeOverridesCapturedRoute() {
        let classifier = AgentRestoreRouteClassifier()
        let direct = AgentRestoreRequest(
            mode: .direct,
            kind: "codex",
            checkpointID: nil,
            source: nil,
            workingDirectory: nil,
            environment: ["CODEX_HOME": "/captured/team-1"],
            launchCommand: AgentLaunchCommand(
                launcher: "codex",
                arguments: ["codex", "-c", "model_provider=\"subrouter\""]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )

        #expect(classifier.route(for: direct) == .direct)
    }

    private func request(
        kind: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> AgentRestoreRequest {
        AgentRestoreRequest(
            mode: .resumeAgent,
            kind: kind,
            checkpointID: "checkpoint",
            source: "agent-hook",
            workingDirectory: "/saved/worktree",
            environment: environment,
            launchCommand: AgentLaunchCommand(
                launcher: kind,
                arguments: arguments,
                environment: environment
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
    }
}
