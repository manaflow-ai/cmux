/// A lightweight process projection used to plan agent argument decoding.
public struct AgentProcessCandidate: Equatable, Sendable {
    /// The Darwin process identifier.
    public let processID: Int

    /// The process name reported by the process snapshot.
    public let name: String

    /// The executable path reported by the process snapshot, when available.
    public let path: String?

    /// Whether the process owns its terminal's foreground process group.
    public let isTerminalForegroundProcessGroup: Bool

    /// Whether app-owned agent definitions require inspecting this process's arguments.
    public let shouldInspectArguments: Bool

    /// Creates a lightweight process candidate.
    ///
    /// - Parameters:
    ///   - processID: The Darwin process identifier.
    ///   - name: The process name reported by the process snapshot.
    ///   - path: The executable path reported by the process snapshot.
    ///   - isTerminalForegroundProcessGroup: Whether the process owns its
    ///     terminal's foreground process group.
    ///   - shouldInspectArguments: Whether app-owned definitions require
    ///     inspecting this process's arguments.
    public init(
        processID: Int,
        name: String,
        path: String?,
        isTerminalForegroundProcessGroup: Bool,
        shouldInspectArguments: Bool
    ) {
        self.processID = processID
        self.name = name
        self.path = path
        self.isTerminalForegroundProcessGroup = isTerminalForegroundProcessGroup
        self.shouldInspectArguments = shouldInspectArguments
    }
}
