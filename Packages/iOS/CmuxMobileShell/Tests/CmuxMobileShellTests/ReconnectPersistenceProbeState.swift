actor ReconnectPersistenceProbeState {
    private let failFirstLoadAfterWrite: Bool
    private var hasWritten = false
    private var didFailLoad = false
    private var removeCount = 0
    private var setActiveCount = 0
    private var rollbackCount = 0

    init(failFirstLoadAfterWrite: Bool) {
        self.failFirstLoadAfterWrite = failFirstLoadAfterWrite
    }

    func recordWrite() {
        hasWritten = true
    }

    func shouldFailLoad() -> Bool {
        guard failFirstLoadAfterWrite, hasWritten, !didFailLoad else { return false }
        didFailLoad = true
        return true
    }

    func recordRemove() {
        removeCount += 1
    }

    func recordSetActive() {
        setActiveCount += 1
    }

    func recordRollback() {
        rollbackCount += 1
    }

    func mutationCounts() -> (removes: Int, setActive: Int, rollbacks: Int) {
        (removeCount, setActiveCount, rollbackCount)
    }
}
