import CMUXAgentLaunch
import Testing

@Suite("AgentResumeRetryPolicy")
struct AgentResumeRetryPolicyTests {
    @Test("Codex policy matches the transient state database lock signatures")
    func codexStateDatabaseLockMatchesIssueSignatures() {
        let policy = AgentResumeRetryPolicy.codexStateDatabaseLock

        #expect(policy.matches(output: "error returned from database: (code: 5) database is locked"))
        #expect(policy.matches(output: "Codex couldn't start because another Codex process is using its local data."))
        #expect(!policy.matches(output: "permission denied"))
        #expect(!AgentResumeRetryPolicy.disabled.matches(output: "database is locked"))
    }

    @Test("Codex kind and codex-teams launcher opt into lock retries")
    func codexLaunchesOptIntoLockRetries() {
        #expect(AgentResumeRetryPolicy.policy(agentKind: "codex").isEnabled)
        #expect(AgentResumeRetryPolicy.policy(agentKind: "claude", launcher: "codexTeams").isEnabled)
        #expect(!AgentResumeRetryPolicy.policy(agentKind: "claude").isEnabled)
    }
}
