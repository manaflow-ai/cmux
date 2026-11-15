/// What a quit that ends the local sessions takes with it: the agents in a
/// turn and the open terminals. "Quit cmux?" names both counts.
public struct QuitLosses: Equatable, Sendable {
    /// Agents in a turn (this Mac's and Chief's).
    public var agents: Int
    /// Live local terminals.
    public var terminals: Int

    public init(agents: Int, terminals: Int) {
        self.agents = agents
        self.terminals = terminals
    }

    public var isEmpty: Bool { agents == 0 && terminals == 0 }
}
