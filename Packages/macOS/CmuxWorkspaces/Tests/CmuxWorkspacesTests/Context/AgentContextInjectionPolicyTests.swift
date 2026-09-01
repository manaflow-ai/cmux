import Testing
@testable import CmuxWorkspaces

@Suite("Agent context injection gating")
struct AgentContextInjectionPolicyTests {
    private let policy = AgentContextInjectionPolicy()

    private func input(
        lifecycle: AgentContextLifecycleState = .idle,
        shell: PanelShellActivityState = .commandRunning,
        action: AgentContextInjectionAction = .compact,
        pressureConfirmed: Bool = true,
        providerEvidenceConfirmed: Bool = true,
        foregroundAgentConfirmed: Bool = true,
        preserveState: Bool = false,
        dialogOpen: Bool = false,
        userInputObserved: Bool = false,
        injectionInFlight: Bool = false,
        preservationCompleted: Bool = false,
        preservationAwaitingAcknowledgement: Bool = false,
        manualRecoveryRequired: Bool = false,
        surfaceAvailable: Bool = true,
        preservationAvailable: Bool = true
    ) -> AgentContextInjectionInput {
        AgentContextInjectionInput(
            enabled: true,
            pressureDetected: true,
            pressureConfirmed: pressureConfirmed,
            providerEvidenceConfirmed: providerEvidenceConfirmed,
            managedSessionBound: true,
            foregroundAgentConfirmed: foregroundAgentConfirmed,
            provider: .claudeCode,
            lifecycle: lifecycle,
            shellActivity: shell,
            dialogOpen: dialogOpen,
            userInputObserved: userInputObserved,
            injectionInFlight: injectionInFlight,
            action: action,
            preserveState: preserveState,
            preservationCompleted: preservationCompleted,
            preservationAwaitingAcknowledgement: preservationAwaitingAcknowledgement,
            manualRecoveryRequired: manualRecoveryRequired,
            surfaceAvailable: surfaceAvailable,
            preservationAvailable: preservationAvailable
        )
    }

    @Test("Only an authoritatively idle agent can receive compact")
    func idleOnly() {
        let decision = policy.decide(input())

        #expect(decision == .inject(.compact))
    }

    @Test("Textual pressure waits for a fresh lifecycle boundary")
    func pressureNeedsLifecycleConfirmation() {
        #expect(
            policy.decide(input(pressureConfirmed: false))
                == .wait(.pressureUnconfirmed)
        )
        #expect(
            policy.decide(input(action: .clear, pressureConfirmed: false))
                == .unsafe(.pressureUnconfirmed)
        )
    }

    @Test("Textual pressure also needs provider-originated evidence")
    func providerEvidenceIsRequired() {
        #expect(
            policy.decide(input(providerEvidenceConfirmed: false))
                == .wait(.pressureUnconfirmed)
        )
        #expect(
            policy.decide(input(action: .clear, providerEvidenceConfirmed: false))
                == .wait(.pressureUnconfirmed)
        )
    }

    @Test("A generic running shell cannot stand in for the foreground agent")
    func foregroundAgentIdentityIsRequired() {
        #expect(
            policy.decide(input(foregroundAgentConfirmed: false))
                == .wait(.foregroundAgentUnconfirmed)
        )
        #expect(
            policy.decide(input(action: .clear, foregroundAgentConfirmed: false))
                == .unsafe(.foregroundAgentUnconfirmed)
        )
    }

    @Test("Unavailable delivery surfaces fail closed")
    func unavailableSurfaceAndPreservationAreReported() {
        #expect(
            policy.decide(input(surfaceAvailable: false))
                == .wait(.surfaceUnavailable)
        )
        #expect(
            policy.decide(input(action: .clear, surfaceAvailable: false))
                == .unsafe(.surfaceUnavailable)
        )
        #expect(
            policy.decide(input(action: .clear, preserveState: true, preservationAvailable: false))
                == .unsafe(.preservationUnavailable)
        )
    }

    @Test("A prior unsafe clear requires manual recovery")
    func manualRecoveryBlocksAutomation() {
        #expect(
            policy.decide(input(manualRecoveryRequired: true))
                == .wait(.manualInterventionRequired)
        )
        #expect(
            policy.decide(input(action: .clear, manualRecoveryRequired: true))
                == .unsafe(.manualInterventionRequired)
        )
    }

    @Test("A running turn fails closed")
    func inFlightTurnIsRejected() {
        let decision = policy.decide(input(lifecycle: .running))

        #expect(decision == .wait(.agentRunning))
    }

    @Test("Needs-input dialogs never receive automation")
    func dialogIsRejected() {
        let decision = policy.decide(input(lifecycle: .needsInput, dialogOpen: true))

        #expect(decision == .unsafe(.dialogOpen))
    }

    @Test("Explicit user input cancels an otherwise eligible injection")
    func userInputWins() {
        let decision = policy.decide(input(userInputObserved: true))

        #expect(decision == .wait(.userInputObserved))
    }

    @Test("User input wins over an in-flight automation record")
    func userInputWinsWhenAutomationIsMarkedInFlight() {
        let decision = policy.decide(input(userInputObserved: true, injectionInFlight: true))

        #expect(decision == .wait(.userInputObserved))
    }

    @Test("Unknown lifecycle and shell state are both ambiguous")
    func ambiguousStateFailsClosed() {
        #expect(policy.decide(input(lifecycle: .unknown)) == .wait(.lifecycleUnknown))
        #expect(policy.decide(input(shell: .unknown)) == .wait(.shellStateUnknown))
    }

    @Test("Clear with preservation requests the preservation phase first")
    func preservationPrecedesClear() {
        let decision = policy.decide(input(action: .clear, preserveState: true))

        #expect(decision == .inject(.preserveState))
        #expect(
            policy.decide(input(action: .clear, preserveState: true, preservationCompleted: true))
                == .inject(.clear)
        )
        #expect(
            policy.decide(input(action: .clear, preserveState: false))
                == .inject(.clear)
        )
    }

    @Test("A preservation instruction is not sent twice while awaiting its boundary")
    func preservationWaitsForAcknowledgement() {
        #expect(
            policy.decide(input(action: .clear, preserveState: true, preservationAwaitingAcknowledgement: true))
                == .wait(.preservationInFlight)
        )
    }

    @Test("A clear that is unsafe is surfaced distinctly")
    func unsafeClearIsDistinct() {
        let decision = policy.decide(input(lifecycle: .running, action: .clear))

        #expect(decision == AgentContextInjectionDecision.unsafe(.agentRunning))
        #expect(
            policy.decide(input(lifecycle: .unknown, action: .clear))
                == AgentContextInjectionDecision.unsafe(.lifecycleUnknown)
        )
        #expect(
            policy.decide(input(shell: .unknown, action: .clear))
                == AgentContextInjectionDecision.unsafe(.shellStateUnknown)
        )
        #expect(
            policy.decide(input(action: .clear, userInputObserved: true))
                == AgentContextInjectionDecision.unsafe(.userInputObserved)
        )
    }

    @Test("Fresh-context commands are provider native")
    func providerNativeCommands() {
        #expect(AgentContextProvider.claudeCode.recoveryCommand(for: .compact) == "/compact")
        #expect(AgentContextProvider.claudeCode.recoveryCommand(for: .clear) == "/clear")
        #expect(AgentContextProvider.codex.recoveryCommand(for: .compact) == "/compact")
        #expect(AgentContextProvider.codex.recoveryCommand(for: .clear) == "/clear")
    }
}
