/// Records whether a session working directory is trusted to select a persistence root.
enum AgentChatWorkingDirectoryAuthority: Sendable, Equatable {
    /// No source has established the directory.
    case unknown
    /// Best-effort process observation, such as an inherited `PWD`.
    case processObservation
    /// A directory attached by cmux when launching or resuming the agent.
    case cmuxLaunch
    /// A directory reported by the agent hook lifecycle or hook store.
    case hook

    var authorizesArtifactPersistence: Bool {
        switch self {
        case .cmuxLaunch, .hook:
            return true
        case .unknown, .processObservation:
            return false
        }
    }
}
