import CmuxIrohTransport

/// Test auth source that briefly fails while a broker 401 recovery refreshes.
actor FlakyAccountSnapshotSource {
    private let stale: CmxIrohAccountCredentialSnapshot
    private let fresh: CmxIrohAccountCredentialSnapshot
    private var snapshotCount = 0
    private(set) var forceRefreshCount = 0

    init(
        stale: CmxIrohAccountCredentialSnapshot,
        fresh: CmxIrohAccountCredentialSnapshot
    ) {
        self.stale = stale
        self.fresh = fresh
    }

    func snapshot() throws -> CmxIrohAccountCredentialSnapshot? {
        snapshotCount += 1
        if snapshotCount == 2 {
            throw CmxIrohBrokerTokenRecoveryError.transient
        }
        return snapshotCount == 1 ? stale : fresh
    }

    func forceRefresh() {
        forceRefreshCount += 1
    }
}
