/// An immutable, live-bottom terminal snapshot for one process generation.
public struct AgentTerminalScreenSnapshot: Sendable, Equatable {
    /// The stable foreground process and runtime identity.
    public let processIdentity: AgentTerminalProcessIdentity
    /// The recognized profile identifier, or `nil` for an unsupported process.
    public let familyID: String?
    /// VT-formatted physical rows from the live terminal bottom.
    public let liveBottomVT: String
    /// The last reliable state, used only while an agent-owned history view is current.
    public let previousReliableState: AgentTerminalSemanticState?

    /// Creates immutable classification evidence.
    public init(
        processIdentity: AgentTerminalProcessIdentity,
        familyID: String?,
        liveBottomVT: String,
        previousReliableState: AgentTerminalSemanticState? = nil
    ) {
        self.processIdentity = processIdentity
        self.familyID = familyID
        self.liveBottomVT = liveBottomVT
        self.previousReliableState = previousReliableState
    }
}
