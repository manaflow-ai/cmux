enum StoredMacReconnectOperationOutcome: Sendable {
    case connected(StoredMacReconnectSuccess)
    case unavailable
    case failed(hasKnownPairedMac: Bool?)
}
