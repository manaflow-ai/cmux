/// Pure fail-closed policy for terminal-side context recovery.
public struct AgentContextInjectionPolicy: Sendable {
    /// Creates the default policy.
    public init() {}

    /// Evaluates whether exactly one recovery step is safe to inject.
    ///
    /// - Parameter input: The complete immutable evidence available for the pane.
    /// - Returns: An approved injection step, a signal to wait, or an unsafe result.
    public func decide(_ input: AgentContextInjectionInput) -> AgentContextInjectionDecision {
        guard input.enabled else { return .wait(.disabled) }
        guard input.pressureDetected else { return .wait(.noPressure) }
        guard input.providerEvidenceConfirmed else {
            // Structured provider evidence may arrive after the PTY marker;
            // keep both actions pending rather than treating the normal
            // ordering gap as a destructive-clear failure.
            return .wait(.pressureUnconfirmed)
        }
        guard input.pressureConfirmed else {
            return input.action == .clear
                ? .unsafe(.pressureUnconfirmed)
                : .wait(.pressureUnconfirmed)
        }
        guard input.managedSessionBound else { return .wait(.unmanagedSession) }
        guard input.surfaceAvailable else {
            return input.action == .clear
                ? .unsafe(.surfaceUnavailable)
                : .wait(.surfaceUnavailable)
        }
        guard input.foregroundAgentConfirmed else {
            return input.action == .clear
                ? .unsafe(.foregroundAgentUnconfirmed)
                : .wait(.foregroundAgentUnconfirmed)
        }
        guard !input.manualRecoveryRequired else {
            return input.action == .clear
                ? .unsafe(.manualInterventionRequired)
                : .wait(.manualInterventionRequired)
        }
        // Explicit input is the strongest signal in the policy. It must win
        // even when an automation sequence or dialog state was already
        // recorded, so cmux never races a user for the PTY.
        guard !input.userInputObserved else {
            return input.action == .clear ? .unsafe(.userInputObserved) : .wait(.userInputObserved)
        }
        // A modal provider/feed dialog always wins over any in-flight phase;
        // callers can surface an unsafe clear instead of silently waiting.
        guard !input.dialogOpen else { return .unsafe(.dialogOpen) }
        guard !input.injectionInFlight else { return .wait(.injectionInFlight) }
        guard !input.preservationAwaitingAcknowledgement else {
            return .wait(.preservationInFlight)
        }

        switch input.lifecycle {
        case .unknown:
            return input.action == .clear ? .unsafe(.lifecycleUnknown) : .wait(.lifecycleUnknown)
        case .running:
            return input.action == .clear ? .unsafe(.agentRunning) : .wait(.agentRunning)
        case .needsInput:
            return .unsafe(.dialogOpen)
        case .idle:
            break
        }

        if input.action == .clear,
           input.preserveState,
           !input.preservationCompleted,
           !input.preservationAvailable {
            return .unsafe(.preservationUnavailable)
        }

        guard input.shellActivity != .unknown else {
            return input.action == .clear ? .unsafe(.shellStateUnknown) : .wait(.shellStateUnknown)
        }
        // A managed agent TUI keeps the shell's foreground command running
        // while it waits at its own prompt.  A shell-level prompt is a
        // different state: the agent may have exited and sending `/compact`
        // would execute arbitrary text in the user's shell.
        guard input.shellActivity == .commandRunning else {
            return input.action == .clear ? .unsafe(.shellPromptIdle) : .wait(.shellPromptIdle)
        }
        guard input.provider == .claudeCode || input.provider == .codex else {
            return .wait(.unmanagedSession)
        }

        switch input.action {
        case .compact:
            return .inject(.compact)
        case .clear:
            if input.preserveState, !input.preservationCompleted {
                return .inject(.preserveState)
            }
            return .inject(.clear)
        }
    }
}
