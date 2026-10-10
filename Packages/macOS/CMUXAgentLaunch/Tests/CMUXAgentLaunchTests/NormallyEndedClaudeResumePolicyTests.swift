import Testing
@testable import CMUXAgentLaunch

@Suite
struct NormallyEndedClaudeResumePolicyTests {
    private let policy = NormallyEndedClaudeResumePolicy()

    @Test("Only an explicit completed marker selects native Claude resume")
    func nativeResumeRequiresExplicitCompletion() {
        #expect(policy.usesLocalRestoreVerb(
            requested: true,
            agentKind: "claude",
            hadActivePromptTurn: false
        ) == false)
        #expect(policy.usesLocalRestoreVerb(
            requested: true,
            agentKind: "claude",
            hadActivePromptTurn: true
        ))
        #expect(policy.usesLocalRestoreVerb(
            requested: true,
            agentKind: "claude",
            hadActivePromptTurn: nil
        ))
        #expect(policy.usesLocalRestoreVerb(
            requested: true,
            agentKind: "codex",
            hadActivePromptTurn: false
        ))
        #expect(policy.usesLocalRestoreVerb(
            requested: false,
            agentKind: "claude",
            hadActivePromptTurn: false
        ) == false)
    }

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
        bindingKind: String? = "claude",
        bindingSessionID: String? = "session-123",
        bindingSource: String? = "agent-hook",
        autoResume: Bool? = true
    ) -> NormallyEndedClaudeResumePolicy.AdmissionEvidence {
        NormallyEndedClaudeResumePolicy.AdmissionEvidence(
            agentKind: agentKind,
            agentSessionID: agentSessionID,
            hadActivePromptTurn: hadActivePromptTurn,
            bindingKind: bindingKind,
            bindingSessionID: bindingSessionID,
            bindingSource: bindingSource,
            autoResume: autoResume
        )
    }
}
