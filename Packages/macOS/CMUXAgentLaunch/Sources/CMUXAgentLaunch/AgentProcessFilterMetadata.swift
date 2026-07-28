/// Lightweight process metadata used to decide whether full argv decoding is useful.
public struct AgentProcessFilterMetadata: Sendable {
    /// The cmux launch directory when present, otherwise the process `PWD`.
    public let projectWorkingDirectory: String?

    /// Whether any argument contains one of the caller's normalized needles.
    public let argumentsContainAnyNeedle: Bool

    /// The agent kind recorded by cmux at launch.
    public let agentLaunchKind: String?

    /// The agent executable recorded by cmux at launch.
    public let agentLaunchExecutable: String?

    /// The first argv element after the process executable.
    public let firstArgumentAfterExecutable: String?

    init(
        projectWorkingDirectory: String?,
        argumentsContainAnyNeedle: Bool,
        agentLaunchKind: String?,
        agentLaunchExecutable: String?,
        firstArgumentAfterExecutable: String?
    ) {
        self.projectWorkingDirectory = projectWorkingDirectory
        self.argumentsContainAnyNeedle = argumentsContainAnyNeedle
        self.agentLaunchKind = agentLaunchKind
        self.agentLaunchExecutable = agentLaunchExecutable
        self.firstArgumentAfterExecutable = firstArgumentAfterExecutable
    }
}
