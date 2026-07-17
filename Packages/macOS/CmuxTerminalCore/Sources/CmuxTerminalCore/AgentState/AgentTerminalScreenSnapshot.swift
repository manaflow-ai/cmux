/// An immutable, live-bottom terminal snapshot for one process generation.
public struct AgentTerminalScreenSnapshot: Sendable, Equatable {
    /// The stable foreground process and runtime identity.
    public let processIdentity: AgentTerminalProcessIdentity
    /// The recognized profile identifier, or `nil` for an unsupported process.
    public let familyID: String?
    /// Plain rendered text from the bounded active-screen bottom.
    public let liveBottomText: String
    /// The last reliable state, used only while an agent-owned history view is current.
    public let previousReliableState: AgentTerminalSemanticState?

    /// Creates immutable classification evidence.
    public init(
        processIdentity: AgentTerminalProcessIdentity,
        familyID: String?,
        liveBottomText: String,
        previousReliableState: AgentTerminalSemanticState? = nil
    ) {
        self.processIdentity = processIdentity
        self.familyID = familyID
        self.liveBottomText = liveBottomText
        self.previousReliableState = previousReliableState
    }
}
