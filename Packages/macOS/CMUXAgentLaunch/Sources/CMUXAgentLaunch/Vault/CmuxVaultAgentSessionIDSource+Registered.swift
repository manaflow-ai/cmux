extension CmuxVaultAgentSessionIDSource {
    /// The package-owned ``RegisteredAgentSessionIDKind`` mirror of this app-side
    /// session-id-source, so the registration-decoupled resolver can branch on
    /// layout without seeing the app's Codable enum.
    public var registeredAgentKind: RegisteredAgentSessionIDKind {
        switch self {
        case .argvOption:
            return .argvOption
        case .piSessionFile:
            return .piSessionFile
        case .grokSessionDirectory:
            return .grokSessionDirectory
        }
    }
}
