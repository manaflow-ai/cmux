/// Immutable lifecycle facts supplied to the stall supervisor at a turn boundary.
public struct AgentStallSupervisorInput: Equatable, Sendable {
    /// Provider/session identity observed for the managed pane.
    public let session: AgentStallSessionIdentity
    /// Classification produced from output captured during this turn.
    public let classification: AgentStallClassification?
    /// Generation that produced the captured output.
    public let observedGeneration: UInt64?
    /// Current shell command generation.
    public let activeGeneration: UInt64
    /// Whether cmux has an active managed lifecycle for this pane.
    public let hasManagedLifecycle: Bool
    /// Whether the retained resume binding is complete and authoritative.
    public let hasManagedBinding: Bool
    /// Whether the binding identity still matches this session.
    public let bindingMatches: Bool
    /// Authoritative managed-agent prompt-boundary evidence.
    public let promptBoundary: AgentStallPromptBoundary
    /// Current liveness of the process bound to the managed session.
    public let processLiveness: AgentStallProcessLiveness
    /// Whether the user explicitly interrupted or exited the session.
    public let userInterrupted: Bool
    /// Whether the turn was known to complete normally.
    public let normalCompletion: Bool
    /// Whether automatic retries are enabled in settings.
    public let autoRetryEnabled: Bool
    /// Number of retry attempts already launched for this generation.
    public let completedRetryAttempts: Int

    /// Creates one supervisor evaluation input.
    ///
    /// - Parameters:
    ///   - session: Managed provider and checkpoint identity.
    ///   - classification: Output classification, when one rule matched.
    ///   - observedGeneration: Capture generation associated with the output.
    ///   - activeGeneration: Current managed turn generation.
    ///   - hasManagedLifecycle: Whether an authoritative managed lifecycle exists.
    ///   - hasManagedBinding: Whether the retained resume binding is complete.
    ///   - bindingMatches: Whether binding and process identity still match the turn.
    ///   - promptBoundary: Authoritative prompt-boundary evidence.
    ///   - processLiveness: Liveness of the captured managed process generation.
    ///   - userInterrupted: Whether explicit user input cancelled recovery.
    ///   - normalCompletion: Whether a hook proved successful completion.
    ///   - autoRetryEnabled: Whether retryable actions are opted in.
    ///   - completedRetryAttempts: Retry commands already launched for the turn chain.
    public init(
        session: AgentStallSessionIdentity,
        classification: AgentStallClassification?,
        observedGeneration: UInt64?,
        activeGeneration: UInt64,
        hasManagedLifecycle: Bool,
        hasManagedBinding: Bool,
        bindingMatches: Bool,
        promptBoundary: AgentStallPromptBoundary,
        processLiveness: AgentStallProcessLiveness,
        userInterrupted: Bool,
        normalCompletion: Bool,
        autoRetryEnabled: Bool,
        completedRetryAttempts: Int
    ) {
        self.session = session
        self.classification = classification
        self.observedGeneration = observedGeneration
        self.activeGeneration = activeGeneration
        self.hasManagedLifecycle = hasManagedLifecycle
        self.hasManagedBinding = hasManagedBinding
        self.bindingMatches = bindingMatches
        self.promptBoundary = promptBoundary
        self.processLiveness = processLiveness
        self.userInterrupted = userInterrupted
        self.normalCompletion = normalCompletion
        self.autoRetryEnabled = autoRetryEnabled
        self.completedRetryAttempts = completedRetryAttempts
    }
}
