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

    /// The bundled cmux CLI path exported to the process.
    public let bundledCLIPath: String?

    /// The process executable at `argv[0]`, retained for identity matching.
    public let executableArgument: String?

    /// The first argv element after the process executable when cmux launch
    /// metadata is present.
    public let firstArgumentAfterExecutable: String?
}
