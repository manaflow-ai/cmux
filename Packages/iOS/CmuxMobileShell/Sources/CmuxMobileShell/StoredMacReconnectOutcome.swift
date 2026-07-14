/// Terminal result of one stored-Mac reconnect operation.
enum StoredMacReconnectOutcome: Equatable {
    case connected
    case unavailable
    case failed
}
