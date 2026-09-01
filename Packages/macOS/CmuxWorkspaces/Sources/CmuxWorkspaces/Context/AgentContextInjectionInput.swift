/// Immutable evidence consumed by ``AgentContextInjectionPolicy``.
public struct AgentContextInjectionInput: Equatable, Sendable {
    /// Whether the opt-in setting is enabled.
    public let enabled: Bool
    /// Whether the detector has observed pressure since recovery.
    public let pressureDetected: Bool
    /// Whether a fresh provider running-to-idle boundary confirmed the
    /// pressure episode.
    public let pressureConfirmed: Bool
    /// Whether an accepted, provider-originated lifecycle event confirmed the
    /// pressure episode. Terminal text remains diagnostic until this evidence
    /// is present.
    public let providerEvidenceConfirmed: Bool
    /// Whether the pane still has an authoritative managed-session binding.
    public let managedSessionBound: Bool
    /// Provider identity for this pane.
    public let provider: AgentContextProvider
    /// Agent lifecycle evidence.
    public let lifecycle: AgentContextLifecycleState
    /// Shell integration state. `.commandRunning` is valid for an agent TUI
    /// whose own lifecycle is idle; `.unknown` remains fail-closed.
    public let shellActivity: PanelShellActivityState
    /// Whether a permission or other modal dialog is open.
    public let dialogOpen: Bool
    /// Whether explicit user input arrived after pressure was detected.
    public let userInputObserved: Bool
    /// Whether another automated PTY sequence is in flight.
    public let injectionInFlight: Bool
    /// The configured recovery action.
    public let action: AgentContextInjectionAction
    /// Whether a preservation instruction should precede `.clear`.
    public let preserveState: Bool
    /// Whether a lifecycle boundary and durable handoff-file evidence completed preservation.
    public let preservationCompleted: Bool
    /// Whether a preservation instruction is awaiting its lifecycle boundary.
    public let preservationAwaitingAcknowledgement: Bool
    /// Whether a previous destructive-clear decision requires manual recovery
    /// before another automated write may be attempted.
    public let manualRecoveryRequired: Bool

    /// Creates immutable policy input.
    ///
    /// - Parameters:
    ///   - enabled: Whether terminal-side recovery is enabled.
    ///   - pressureDetected: Whether provider pressure output has been observed.
    ///   - pressureConfirmed: Whether a fresh provider running-to-idle boundary
    ///     confirmed the pressure episode.
    ///   - providerEvidenceConfirmed: Whether an accepted provider lifecycle
    ///     event independently confirmed the pressure episode.
    ///   - managedSessionBound: Whether the pane still has a complete managed-session binding.
    ///   - provider: The managed provider that owns the pane.
    ///   - lifecycle: Authoritative provider lifecycle evidence.
    ///   - shellActivity: Current shell-integration activity for the pane.
    ///   - dialogOpen: Whether any panel-scoped dialog is open.
    ///   - userInputObserved: Whether user input cancelled pending automation.
    ///   - injectionInFlight: Whether a recovery write is already being delivered.
    ///   - action: The configured semantic recovery action.
    ///   - preserveState: Whether clear should first request a durable handoff note.
    ///   - preservationCompleted: Whether the handoff request completed a lifecycle boundary and file check.
    ///   - preservationAwaitingAcknowledgement: Whether the handoff request is still in flight.
    ///   - manualRecoveryRequired: Whether a prior unsafe clear requires manual recovery.
    public init(
        enabled: Bool,
        pressureDetected: Bool,
        pressureConfirmed: Bool = false,
        providerEvidenceConfirmed: Bool = false,
        managedSessionBound: Bool,
        provider: AgentContextProvider,
        lifecycle: AgentContextLifecycleState,
        shellActivity: PanelShellActivityState,
        dialogOpen: Bool,
        userInputObserved: Bool,
        injectionInFlight: Bool,
        action: AgentContextInjectionAction,
        preserveState: Bool,
        preservationCompleted: Bool,
        preservationAwaitingAcknowledgement: Bool = false,
        manualRecoveryRequired: Bool = false
    ) {
        self.enabled = enabled
        self.pressureDetected = pressureDetected
        self.pressureConfirmed = pressureConfirmed
        self.providerEvidenceConfirmed = providerEvidenceConfirmed
        self.managedSessionBound = managedSessionBound
        self.provider = provider
        self.lifecycle = lifecycle
        self.shellActivity = shellActivity
        self.dialogOpen = dialogOpen
        self.userInputObserved = userInputObserved
        self.injectionInFlight = injectionInFlight
        self.action = action
        self.preserveState = preserveState
        self.preservationCompleted = preservationCompleted
        self.preservationAwaitingAcknowledgement = preservationAwaitingAcknowledgement
        self.manualRecoveryRequired = manualRecoveryRequired
    }
}
