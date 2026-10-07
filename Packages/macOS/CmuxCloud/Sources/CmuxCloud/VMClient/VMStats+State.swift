extension VMStats {
    /// Provider activity reported with a stats or resize response.
    public enum State: String, Equatable, Sendable {
        case awake
        case asleep
        case unknown
    }
}
