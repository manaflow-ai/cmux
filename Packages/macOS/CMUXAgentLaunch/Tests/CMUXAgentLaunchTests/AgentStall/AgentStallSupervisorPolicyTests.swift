import CMUXAgentLaunch
import Testing

@Suite("Managed agent stall supervisor policy")
struct AgentStallSupervisorPolicyTests {
    private let classifier = AgentStallClassifier()
    private let policy = AgentStallSupervisorPolicy.standard
    private let session = AgentStallSessionIdentity(provider: "codex", checkpointID: "session-1")

    private func input(
        session: AgentStallSessionIdentity? = nil,
        classification: AgentStallClassification? = nil,
        output: String? = "API error: 429 Too Many Requests — rate limit reached.",
        promptBoundary: AgentStallPromptBoundary = .managedPromptIdle,
        processLiveness: AgentStallProcessLiveness = .running,
        observedGeneration: UInt64? = 7,
        activeGeneration: UInt64 = 7,
        hasManagedLifecycle: Bool = true,
        hasManagedBinding: Bool = true,
        bindingMatches: Bool = true,
        userInterrupted: Bool = false,
        normalCompletion: Bool = false,
        autoRetryEnabled: Bool = true,
        completedRetryAttempts: Int = 0
    ) -> AgentStallSupervisorInput {
        AgentStallSupervisorInput(
            session: session ?? self.session,
            classification: classification ?? output.flatMap {
                classifier.classify(provider: "codex", output: $0)
            },
            observedGeneration: observedGeneration,
            activeGeneration: activeGeneration,
            hasManagedLifecycle: hasManagedLifecycle,
            hasManagedBinding: hasManagedBinding,
            bindingMatches: bindingMatches,
            promptBoundary: promptBoundary,
            processLiveness: processLiveness,
            userInterrupted: userInterrupted,
            normalCompletion: normalCompletion,
            autoRetryEnabled: autoRetryEnabled,
            completedRetryAttempts: completedRetryAttempts
        )
    }

    @Test("retryable banner retries only at a managed-agent prompt boundary")
    func retryAtManagedPrompt() {
        #expect(
            policy.decision(for: input()) ==
                .retry(attempt: 1, maximumAttempts: 3, delaySeconds: 1, actionID: "replayLastPrompt")
        )
        #expect(policy.decision(for: input(promptBoundary: .midTurn)) == .ignore(.notIdle))
        #expect(policy.decision(for: input(promptBoundary: .unknown)) == .ignore(.notIdle))
    }

    @Test("retry and notification require a live process")
    func processLivenessGate() throws {
        #expect(policy.decision(for: input(processLiveness: .exited)) == .ignore(.processExited))
        #expect(policy.decision(for: input(processLiveness: .unknown)) == .ignore(.processUnknown))

        let refusal = try #require(trustedAccessClassification())
        #expect(policy.decision(for: input(
            classification: refusal,
            output: nil,
            processLiveness: .exited
        )) == .ignore(.processExited))
    }

    @Test("retry gating fails closed for lifecycle, binding, generation, and setting")
    func retryGates() {
        #expect(policy.decision(for: input(hasManagedLifecycle: false)) == .ignore(.unmanagedSession))
        #expect(policy.decision(for: input(hasManagedBinding: false)) == .ignore(.invalidBinding))
        #expect(policy.decision(for: input(bindingMatches: false)) == .ignore(.invalidBinding))
        #expect(policy.decision(for: input(observedGeneration: 6)) == .ignore(.staleGeneration))
        #expect(policy.decision(for: input(autoRetryEnabled: false)) == .ignore(.disabled))
    }

    @Test("incomplete and mismatched managed-session identities fail closed")
    func sessionIdentityGates() throws {
        #expect(policy.decision(for: input(
            session: AgentStallSessionIdentity(provider: "codex", checkpointID: "")
        )) == .ignore(.incompleteSession))

        let claudeClassification = try #require(classifier.classify(
            provider: "claude",
            output: "API error: connection reset by peer"
        ))
        #expect(policy.decision(for: input(
            classification: claudeClassification,
            output: nil
        )) == .ignore(.providerMismatch))
    }

    @Test("interrupts, normal completion, and unknown output fail closed")
    func turnOutcomeGates() {
        #expect(policy.decision(for: input(userInterrupted: true)) == .ignore(.userInterrupted))
        #expect(policy.decision(for: input(normalCompletion: true)) == .ignore(.normalCompletion))
        #expect(policy.decision(for: input(output: nil)) == .ignore(.unknownClassification))
    }

    @Test("normal completion suppresses even a human-required banner")
    func normalCompletionSuppressesHumanRequired() throws {
        let refusal = try #require(trustedAccessClassification())
        #expect(policy.decision(for: input(
            classification: refusal,
            output: nil,
            normalCompletion: true
        )) == .ignore(.normalCompletion))
    }

    @Test("human-required causes notify without depending on retry setting or budget")
    func humanRequiredNotification() throws {
        let refusal = try #require(trustedAccessClassification())

        #expect(policy.decision(for: input(
            classification: refusal,
            output: nil,
            autoRetryEnabled: false,
            completedRetryAttempts: 3
        )) == .notify(cause: .safeguardRefusal, suggestedActionID: "trustedAccess"))
    }

    @Test("retry budget uses one, two, and four second delays, then stops")
    func boundedBackoff() {
        #expect(policy.decision(for: input(completedRetryAttempts: 0)) ==
            .retry(attempt: 1, maximumAttempts: 3, delaySeconds: 1, actionID: "replayLastPrompt"))
        #expect(policy.decision(for: input(completedRetryAttempts: 1)) ==
            .retry(attempt: 2, maximumAttempts: 3, delaySeconds: 2, actionID: "replayLastPrompt"))
        #expect(policy.decision(for: input(completedRetryAttempts: 2)) ==
            .retry(attempt: 3, maximumAttempts: 3, delaySeconds: 4, actionID: "replayLastPrompt"))
        #expect(policy.decision(for: input(completedRetryAttempts: 3)) == .ignore(.exhausted))
    }

    @Test("a retryable rule without a provider action fails closed")
    func missingRetryAction() throws {
        let missingActionClassifier = AgentStallClassifier(patterns: [
            AgentStallPattern(
                identifier: "test.retry-without-input",
                providers: ["codex"],
                cause: .transientTransport,
                requiredFragments: ["known transient failure"],
                suggestedActionID: "retryAutomatically"
            ),
        ])
        let classification = try #require(missingActionClassifier.classify(
            provider: "codex",
            output: "Known transient failure"
        ))

        #expect(policy.decision(for: input(
            classification: classification,
            output: nil
        )) == .ignore(.missingRetryAction))
    }

    @Test("provider retry action replays the prior prompt as real terminal keys")
    func retryActionInput() {
        let resolver = AgentStallRetryActionResolver()

        #expect(resolver.input(for: "replayLastPrompt", provider: "claude") == "\u{001B}[A\r")
        #expect(resolver.input(for: "replayLastPrompt", provider: "codex") == "\u{001B}[A\r")
        #expect(resolver.input(for: "unknown", provider: "codex") == nil)
        #expect(resolver.input(for: "replayLastPrompt", provider: "unknown") == nil)
    }

    private func trustedAccessClassification() -> AgentStallClassification? {
        classifier.classify(
            provider: "codex",
            output: """
            This content can't be shown.
            We take extra caution with cybersecurity requests.
            Security professionals may apply for Trusted Access.
            """
        )
    }
}
