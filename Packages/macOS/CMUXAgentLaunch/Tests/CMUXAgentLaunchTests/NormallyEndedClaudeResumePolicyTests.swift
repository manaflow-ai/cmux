import Testing
@testable import CMUXAgentLaunch

@Suite
struct NormallyEndedClaudeResumePolicyTests {
    private let policy = NormallyEndedClaudeResumePolicy()

    @Test("Normal completion admits a matching trusted hook binding")
    func matchingCompletedBindingAdmits() {
        #expect(policy.admits(evidence(
            agentSessionID: " session-123 ",
            bindingSessionID: "session-123"
        )))
    }

    @Test("Deferred and legacy completion markers stay on restore admission", arguments: [true as Bool?, nil])
    func deferredOrUnknownCompletionDoesNotAdmit(hadActivePromptTurn: Bool?) {
        #expect(!policy.admits(evidence(hadActivePromptTurn: hadActivePromptTurn)))
    }

    @Test("A stopped binding-only session admits when the completion marker is absent")
    func stoppedBindingWithoutCompletionMarkerAdmits() {
        #expect(policy.admits(evidence(hadActivePromptTurn: nil, wasAgentRunning: false)))
    }

    @Test("An unknown or running process keeps a missing marker fail closed", arguments: [nil, true])
    func missingMarkerNeedsStoppedProcess(wasAgentRunning: Bool?) {
        #expect(!policy.admits(evidence(hadActivePromptTurn: nil, wasAgentRunning: wasAgentRunning)))
    }

    @Test("Missing or stale bindings fail closed")
    func missingOrStaleBindingDoesNotAdmit() {
        #expect(!policy.admits(evidence(bindingSessionID: nil)))
        #expect(!policy.admits(evidence(bindingSessionID: "other-session")))
    }

    @Test("Binding safety gates reject invalid kind, source, and consent")
    func invalidBindingEvidenceDoesNotAdmit() {
        #expect(!policy.admits(evidence(bindingKind: "codex")))
        #expect(!policy.admits(evidence(bindingSource: "cli")))
        #expect(!policy.admits(evidence(autoResume: false)))
        #expect(!policy.admits(evidence(agentKind: "codex")))
    }

    private func evidence(
        agentKind: String = "claude",
        agentSessionID: String = "session-123",
        hadActivePromptTurn: Bool? = false,
        wasAgentRunning: Bool? = nil,
        bindingKind: String? = "claude",
        bindingSessionID: String? = "session-123",
        bindingSource: String? = "agent-hook",
        autoResume: Bool? = true
    ) -> NormallyEndedClaudeResumePolicy.AdmissionEvidence {
        NormallyEndedClaudeResumePolicy.AdmissionEvidence(
            agentKind: agentKind,
            agentSessionID: agentSessionID,
            hadActivePromptTurn: hadActivePromptTurn,
            wasAgentRunning: wasAgentRunning,
            bindingKind: bindingKind,
            bindingSessionID: bindingSessionID,
            bindingSource: bindingSource,
            autoResume: autoResume
        )
    }
}
