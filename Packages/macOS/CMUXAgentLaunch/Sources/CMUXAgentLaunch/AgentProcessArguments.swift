/// A decoded process argument vector and environment.
public struct AgentProcessArguments: Sendable {
    /// The process argument vector in kernel order.
    public let arguments: [String]

    /// Environment values keyed by variable name.
    public let environment: [String: String]

    /// Creates decoded process arguments.
    ///
    /// - Parameters:
    ///   - arguments: The process argument vector in kernel order.
    ///   - environment: Environment values keyed by variable name.
    public init(
        arguments: [String],
        environment: [String: String]
    ) {
        self.arguments = arguments
        self.environment = environment
    }
}
