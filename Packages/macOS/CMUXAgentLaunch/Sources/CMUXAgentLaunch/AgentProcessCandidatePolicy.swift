/// The immutable inputs that control agent process candidate selection.
public struct AgentProcessCandidatePolicy: Sendable {
    let usesBuiltInFastPath: Bool
    let detectionRules: [AgentProcessDetectionRule]
    let builtInAgentBasenames: Set<String>
    let wrapperBasenames: Set<String>

    /// Creates a process candidate policy.
    ///
    /// - Parameters:
    ///   - usesBuiltInFastPath: Whether every active registration is identical
    ///     to a built-in registration.
    ///   - detectionRules: Active agent detection rules.
    ///   - builtInAgentBasenames: Executable basenames recognized by app-owned
    ///     coding-agent definitions.
    ///   - wrapperBasenames: Executable basenames that can launch any agent.
    public init(
        usesBuiltInFastPath: Bool,
        detectionRules: [AgentProcessDetectionRule],
        builtInAgentBasenames: Set<String>,
        wrapperBasenames: Set<String>
    ) {
        self.usesBuiltInFastPath = usesBuiltInFastPath
        self.detectionRules = detectionRules
        self.builtInAgentBasenames = builtInAgentBasenames
        self.wrapperBasenames = wrapperBasenames
    }
}
