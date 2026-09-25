/// The metadata an agent publishes for a terminal pane footer.
public struct AgentFooterState: Equatable, Sendable {
    /// The agent's short display name, or `nil` when no name was published.
    public let agent: String?
    /// The agent's context-window usage, when it is within the inclusive range 0...100.
    public let contextPercent: Int?

    /// Creates one pane footer snapshot.
    ///
    /// - Parameters:
    ///   - agent: The short agent name. Empty names are treated as absent.
    ///   - contextPercent: Context usage as a whole-number percentage.
    public init(agent: String?, contextPercent: Int?) {
        let normalizedAgent = agent?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agent = normalizedAgent?.isEmpty == false ? normalizedAgent : nil
        if let contextPercent, (0...100).contains(contextPercent) {
            self.contextPercent = contextPercent
        } else {
            self.contextPercent = nil
        }
    }

    /// Whether the snapshot asks the pane to hide its footer.
    public var isEmpty: Bool {
        agent == nil && contextPercent == nil
    }
}
