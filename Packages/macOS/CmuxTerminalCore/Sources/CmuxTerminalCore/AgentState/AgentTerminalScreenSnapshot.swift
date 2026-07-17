/// An immutable, live-bottom terminal snapshot for one process generation.
public struct AgentTerminalScreenSnapshot: Sendable, Equatable {
    /// The stable foreground process and runtime identity.
    public let processIdentity: AgentTerminalProcessIdentity
    /// The recognized profile identifier, or `nil` for an unsupported process.
    public let familyID: String?
    /// VT-formatted physical rows from the live terminal bottom.
    public let liveBottomVT: String
    /// The current terminal title, when captured for this generation.
    public let title: String?
    /// The current terminal progress metadata, when available.
    public let progress: String?
    /// The last reliable state, used only while an agent-owned history view is current.
    public let previousReliableState: AgentTerminalSemanticState?

    /// Creates immutable classification evidence.
    public init(
        processIdentity: AgentTerminalProcessIdentity,
        familyID: String?,
        liveBottomVT: String,
        title: String? = nil,
        progress: String? = nil,
        previousReliableState: AgentTerminalSemanticState? = nil
    ) {
        self.processIdentity = processIdentity
        self.familyID = familyID
        self.liveBottomVT = liveBottomVT
        self.title = title
        self.progress = progress
        self.previousReliableState = previousReliableState
    }
}
