/// Counts active agents by the state shown in the sidebar.
public struct SidebarAgentActivityCounts: Equatable, Hashable, Sendable {
    /// The number of agents currently running.
    public var running: Int

    /// The number of agents waiting for user input.
    public var needsInput: Int

    /// Creates sidebar agent counts.
    ///
    /// - Parameters:
    ///   - running: The number of running agents.
    ///   - needsInput: The number of agents waiting for input.
    public init(running: Int = 0, needsInput: Int = 0) {
        self.running = running
        self.needsInput = needsInput
    }

    /// Adds counts from two sidebar scopes.
    ///
    /// - Parameters:
    ///   - lhs: Counts from the first scope.
    ///   - rhs: Counts from the second scope.
    /// - Returns: The combined counts.
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            running: lhs.running + rhs.running,
            needsInput: lhs.needsInput + rhs.needsInput
        )
    }
}
