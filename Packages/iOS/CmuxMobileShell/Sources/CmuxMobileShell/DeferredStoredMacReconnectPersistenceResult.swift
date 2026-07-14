import CmuxMobilePairedMac

enum DeferredStoredMacReconnectPersistenceResult {
    case skipped
    case persisted(visibleMacs: [MobilePairedMac])
}
