/// Explicit executor boundary for the Vault's initial filesystem snapshot.
struct SessionIndexSnapshotLoader: Sendable {
    typealias LoadOperation = @Sendable () async -> [SessionEntry]

    private let loadOperation: LoadOperation

    init() {
        self.loadOperation = {
            await SessionIndexStore.loadInitialEntries()
        }
    }

    init(loadOperation: @escaping LoadOperation) {
        self.loadOperation = loadOperation
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func load() async -> [SessionEntry] {
        await loadOperation()
    }
}
