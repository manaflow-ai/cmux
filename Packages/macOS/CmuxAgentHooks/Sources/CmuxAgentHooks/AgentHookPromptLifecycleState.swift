/// Pure persisted state for an agent hook's active and most recently completed prompt.
public struct AgentHookPromptLifecycleState: Sendable, Equatable {
    /// The number of active prompt frames, or `nil` when the projection is idle.
    public private(set) var depth: Int?

    /// The most recently active turn identifier, when the provider supplies one.
    public private(set) var activeTurnID: String?

    /// The active turn stack, when turn identifiers are available.
    public private(set) var activeTurnIDs: [String]?

    /// The most recently observed turn identifier, including after completion.
    public private(set) var lastTurnID: String?

    /// Creates a lifecycle projection from persisted prompt fields.
    ///
    /// - Parameters:
    ///   - depth: The persisted active prompt depth.
    ///   - activeTurnID: The persisted active turn identifier.
    ///   - activeTurnIDs: The persisted active turn stack.
    ///   - lastTurnID: The persisted most recently observed turn identifier.
    public init(
        depth: Int? = nil,
        activeTurnID: String? = nil,
        activeTurnIDs: [String]? = nil,
        lastTurnID: String? = nil
    ) {
        self.depth = depth
        self.activeTurnID = activeTurnID
        self.activeTurnIDs = activeTurnIDs
        self.lastTurnID = lastTurnID
    }

    /// Begins one authoritative prompt, replacing any stale active frame.
    ///
    /// - Parameter turnID: The provider's optional turn identifier.
    public mutating func beginAuthoritativePrompt(turnID: String?) {
        depth = 1
        activeTurnID = turnID
        activeTurnIDs = turnID.map { [$0] }
        lastTurnID = turnID
    }

    /// Ends the authoritative prompt while retaining the last observed turn identifier.
    public mutating func endAuthoritativePrompt() {
        depth = nil
        activeTurnID = nil
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
