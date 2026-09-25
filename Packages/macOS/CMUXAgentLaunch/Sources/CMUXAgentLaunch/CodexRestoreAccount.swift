/// Resolves the literal account path inherited by the final Codex invocation.
public struct CodexRestoreAccount: Sendable {
    /// Creates a stateless resolver.
    public init() {}

    /// Resolves relative paths against the actual launch directory without expanding shell syntax.
    ///
    /// - Parameters:
    ///   - environment: The final child environment, after restoring captured account selection.
    ///   - workingDirectory: The actual launch directory after applying the saved cwd fallback.
    ///   - fallbackHome: User home when the child has no HOME.
    /// - Returns: The exact account path used for provider-lock inspection.
    public func home(environment: [String: String], workingDirectory: String, fallbackHome: String) -> String {
        let explicitHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let userHome = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackHome
        let path = explicitHome ?? userHome + "/.codex"
        return path.hasPrefix("/") ? path : workingDirectory + "/" + path
    }

    /// Recognizes remote ownership without interpreting option values or prompts as flags.
    /// - Parameter arguments: Codex argv, including its executable.
    /// - Returns: Whether the invocation explicitly selects a remote app-server.
    public func usesRemoteProvider(arguments: [String]) -> Bool {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            if argument == "--remote" || argument.hasPrefix("--remote=") { return true }
            if argument.hasPrefix("-") {
                index += AgentLaunchSanitizer.optionWidth(arguments, index: index, policy: AgentLaunchSanitizer.codexPolicy)
            } else {
                index += 1
            }
        }
        return false
    }
}
