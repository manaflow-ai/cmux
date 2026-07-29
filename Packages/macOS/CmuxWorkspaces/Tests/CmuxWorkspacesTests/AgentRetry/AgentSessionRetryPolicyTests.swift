import Testing
@testable import CmuxWorkspaces

@Suite("Agent session retry policy")
struct AgentSessionRetryPolicyTests {
    private let policy = AgentSessionRetryPolicy.standard

    @Test(
        "non-error and ambiguous terminations fail closed",
        arguments: [
            (false, true, true, Optional(1), AgentSessionRetryRejection.disabled),
            (true, false, true, Optional(1), .inactiveSession),
            (true, true, false, Optional(1), .missingResumeBinding),
            (true, true, true, nil, .unknownExit),
            (true, true, true, Optional(0), .successfulExit),
            (true, true, true, Optional(128), .signalExit),
            (true, true, true, Optional(130), .signalExit),
            (true, true, true, Optional(143), .signalExit),
        ]
    )
    func rejectsUnsafeTermination(
        isEnabled: Bool,
        hadActiveSession: Bool,
        hasResumeBinding: Bool,
        exitCode: Int?,
        expected: AgentSessionRetryRejection
    ) {
        let decision = policy.decision(
            for: AgentSessionRetryContext(
                isEnabled: isEnabled,
                hadActiveAgentSession: hadActiveSession,
                hasManagedResumeBinding: hasResumeBinding,
                exitCode: exitCode
            ),
            completedAttempts: 0
        )

        #expect(decision == .reject(expected))
    }

    @Test("qualifying failures receive bounded exponential backoff")
    func qualifyingFailuresBackOff() {
        let context = AgentSessionRetryContext(
            isEnabled: true,
            hadActiveAgentSession: true,
            hasManagedResumeBinding: true,
            exitCode: 1
        )

        #expect(policy.decision(for: context, completedAttempts: 0) ==
            .retry(attempt: 1, maximumAttempts: 3, delaySeconds: 1))
        #expect(policy.decision(for: context, completedAttempts: 1) ==
            .retry(attempt: 2, maximumAttempts: 3, delaySeconds: 2))
        #expect(policy.decision(for: context, completedAttempts: 2) ==
            .retry(attempt: 3, maximumAttempts: 3, delaySeconds: 4))
        #expect(policy.decision(for: context, completedAttempts: 3) ==
            .exhausted(maximumAttempts: 3))
    }

    @Test("non-signal nonzero exits remain eligible")
    func nonSignalErrorsRemainEligible() {
        for exitCode in [1, 5, 65, 127, 193, 255] {
            let context = AgentSessionRetryContext(
                isEnabled: true,
                hadActiveAgentSession: true,
                hasManagedResumeBinding: true,
                exitCode: exitCode
            )
            #expect(policy.decision(for: context, completedAttempts: 0) ==
                .retry(attempt: 1, maximumAttempts: 3, delaySeconds: 1))
        }
    }
}
