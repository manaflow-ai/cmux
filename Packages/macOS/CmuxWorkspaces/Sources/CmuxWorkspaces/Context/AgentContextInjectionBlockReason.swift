/// Why a pressure-management decision was not allowed to inject.
public enum AgentContextInjectionBlockReason: String, Codable, Equatable, Sendable {
    /// The feature is disabled.
    case disabled
    /// No pressure event has been observed.
    case noPressure
    /// Terminal text was observed, but a fresh provider running-to-idle
    /// boundary has not confirmed the pressure episode yet.
    case pressureUnconfirmed
    /// The pane no longer has a managed provider binding.
    case unmanagedSession
    /// The agent lifecycle has not proved idle.
    case lifecycleUnknown
    /// A turn is still in flight.
    case agentRunning
    /// The provider is waiting for user input or a dialog decision.
    case dialogOpen
    /// Shell state is ambiguous.
    case shellStateUnknown
    /// The shell is at its own prompt, so the managed agent is no longer the
    /// foreground process that can receive a slash command.
    case shellPromptIdle
    /// The user typed while automation was pending.
    case userInputObserved
    /// Another recovery input is already being delivered.
    case injectionInFlight
    /// The live terminal surface could not accept an immediate recovery write.
    case surfaceUnavailable
    /// A preservation instruction is waiting for an authoritative lifecycle boundary.
    case preservationInFlight
    /// A durable handoff file could not be proven before a destructive clear.
    case preservationUnavailable
}
