enum StoredMacReconnectOperationOutcome: Sendable {
    case connected(StoredMacReconnectSuccess)
    case unavailable(hasKnownPairedMac: Bool?)
    case failed(hasKnownPairedMac: Bool?)
}
