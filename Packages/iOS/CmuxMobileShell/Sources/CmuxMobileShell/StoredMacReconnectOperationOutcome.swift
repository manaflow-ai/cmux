import CmuxMobileRPC

enum StoredMacReconnectOperationOutcome {
    case connected(StoredMacReconnectSuccess)
    case unavailable(hasKnownPairedMac: Bool?)
    case failed(error: MobileShellConnectionError?, hasKnownPairedMac: Bool?)
}
