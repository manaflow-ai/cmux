extension VMStats {
    /// Provider activity reported with a stats or resize response.
    enum State: String, Equatable, Sendable {
        case awake
        case asleep
        case unknown
    }
}
