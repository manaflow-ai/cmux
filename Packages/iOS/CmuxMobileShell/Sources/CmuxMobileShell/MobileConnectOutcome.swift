/// The internal outcome of one foreground connection attempt.
enum MobileConnectOutcome: Equatable, Sendable {
    /// The target authenticated and became the foreground connection.
    case connected
    /// The attempt completed without a connection and applied this category.
    case failed(MobilePairingFailureCategory)
    /// A newer attempt or owner superseded this attempt before completion.
    case superseded
}

extension MobileConnectOutcome {
    /// Maps a completed foreground outcome into the reconnect state model.
    var storedReconnectOutcome: StoredMacReconnectOutcome? {
        switch self {
        case .connected:
            .connected
        case let .failed(category):
            .failed(category.diagnosticFailureKind)
        case .superseded:
            nil
        }
    }
}
