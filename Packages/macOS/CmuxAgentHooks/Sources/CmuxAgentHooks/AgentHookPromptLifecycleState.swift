/// Pure persisted state for an agent hook's active and most recently completed prompt.
public struct AgentHookPromptLifecycleState: Sendable, Equatable {
    /// The number of active prompt frames, or `nil` when the projection is idle.
    public private(set) var depth: Int?

    /// The most recently active turn identifier, when the provider supplies one.
    public private(set) var activeTurnID: String?

    /// The provider's invocation number for the active prompt, when supplied.
    /// Antigravity increments this for repeated model invocations in one turn
    /// and resets it when a new user turn begins.
    public private(set) var activeInvocationNumber: Int?

    /// The active turn stack, when turn identifiers are available.
    public private(set) var activeTurnIDs: [String]?

    /// The most recently observed turn identifier, including after completion.
    public private(set) var lastTurnID: String?

    /// Creates a lifecycle projection from persisted prompt fields.
    ///
    /// - Parameters:
    ///   - depth: The persisted active prompt depth.
    ///   - activeTurnID: The persisted active turn identifier.
    ///   - activeInvocationNumber: The provider's optional invocation number.
    ///   - activeTurnIDs: The persisted active turn stack.
    ///   - lastTurnID: The persisted most recently observed turn identifier.
    public init(
        depth: Int? = nil,
        activeTurnID: String? = nil,
        activeInvocationNumber: Int? = nil,
        activeTurnIDs: [String]? = nil,
        lastTurnID: String? = nil
    ) {
        self.depth = depth
        self.activeTurnID = activeTurnID
        self.activeInvocationNumber = activeInvocationNumber
        self.activeTurnIDs = activeTurnIDs
        self.lastTurnID = lastTurnID
    }

    /// Begins one authoritative prompt, replacing any stale active frame.
    ///
    /// - Parameters:
    ///   - turnID: The provider's optional turn identifier.
    ///   - invocationNumber: The provider's optional invocation number.
    public mutating func beginAuthoritativePrompt(turnID: String?, invocationNumber: Int? = nil) {
        depth = 1
        activeTurnID = turnID
        if let invocationNumber {
            activeInvocationNumber = invocationNumber
        }
        activeTurnIDs = turnID.map { [$0] }
        // A provider may omit the turn id on a repeated invocation. That is
        // not a new completed-turn observation and must not erase the marker
        // used by restart/deduplication guards.
        if let turnID {
            lastTurnID = turnID
        }
    }

    /// Ends the authoritative prompt while retaining the last observed turn identifier.
    public mutating func endAuthoritativePrompt() {
        depth = nil
        activeTurnID = nil
        activeInvocationNumber = nil
        activeTurnIDs = nil
    }

    /// Clears active prompt fields while retaining the most recently observed turn identifier.
    public mutating func clearActivePromptState() {
        endAuthoritativePrompt()
    }

    /// Clears active and completed prompt markers at a fresh session boundary.
    public mutating func clearPromptStartState() {
        endAuthoritativePrompt()
        lastTurnID = nil
    }
}
