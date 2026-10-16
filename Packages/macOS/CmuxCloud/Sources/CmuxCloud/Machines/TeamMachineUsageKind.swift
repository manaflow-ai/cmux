extension TeamMachineUsage {
    /// Whether the backend has usage records available for this team.
    public enum Kind: String, Sendable {
        case ready
        case unavailable
    }
}
