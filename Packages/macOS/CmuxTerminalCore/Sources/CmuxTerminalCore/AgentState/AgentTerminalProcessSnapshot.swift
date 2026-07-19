/// Bounded foreground-process evidence used to recognize an agent family.
public struct AgentTerminalProcessSnapshot: Sendable, Equatable {
    /// The process generation that owns this snapshot.
    public let identity: AgentTerminalProcessIdentity
    /// The foreground executable path, when available.
    public let executablePath: String?
    /// The bounded foreground command arguments.
    public let arguments: [String]
    /// Host-visible environment hints scoped to the foreground process.
    public let environment: [String: String]

    /// Creates a process snapshot.
    public init(
        identity: AgentTerminalProcessIdentity,
        executablePath: String?,
        arguments: [String],
        environment: [String: String] = [:]
    ) {
        self.identity = identity
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }
}
