extension AgentResumeArgv {
    /// Builds resume arguments for an unmodified registry-owned built-in agent.
    ///
    /// - Parameters:
    ///   - registrationID: The Vault registration identifier.
    ///   - resumeCommand: The registration's current resume-command template.
    ///   - sessionId: The session identifier to resume.
    ///   - executablePath: The captured executable path, if any.
    ///   - arguments: The captured launch arguments, including the executable as element zero.
    /// - Returns: Sanitized built-in resume arguments, or `nil` when the registration is unknown,
    ///   customized, or cannot safely preserve its launch arguments.
    public func registeredBuiltInKind(
        registrationID: String,
        resumeCommand: String,
        sessionId: String,
        executablePath: String?,
        arguments: [String]
    ) -> [String]? {
        guard let kind = RegisteredAgentResumeKind(
            registrationID: registrationID,
            resumeCommand: resumeCommand
        ) else {
            return nil
        }
        return builtInKind(
            kind: kind.rawValue,
            sessionId: sessionId,
            executablePath: executablePath,
            arguments: arguments
        )
    }
}
