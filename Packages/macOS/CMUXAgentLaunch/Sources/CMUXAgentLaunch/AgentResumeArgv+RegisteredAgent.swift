extension AgentResumeArgv {
    /// Builds resume arguments for a registry-owned built-in agent.
    ///
    /// - Parameters:
    ///   - kind: The exact built-in registration kind classified by the registry owner.
    ///   - sessionId: The session identifier to resume.
    ///   - executablePath: The captured executable path, if any.
    ///   - arguments: The captured launch arguments, including the executable as element zero.
    /// - Returns: Sanitized built-in resume arguments, or `nil` when its launch arguments cannot
    ///   be preserved safely.
    public func registeredBuiltInKind(
        kind: RegisteredAgentResumeKind,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        return builtInKind(
            kind: kind.rawValue,
            sessionId: sessionId,
            executablePath: executablePath,
            arguments: arguments
        )
    }
}
