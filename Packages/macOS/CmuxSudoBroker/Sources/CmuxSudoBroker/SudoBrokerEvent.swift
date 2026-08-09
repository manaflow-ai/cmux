/// An authoritative replacement snapshot consumed by the approval coordinator.
public enum SudoBrokerEvent: Sendable, Equatable {
    /// Replaces the complete non-terminal approval set.
    case snapshot([SudoPendingRequest])
}
