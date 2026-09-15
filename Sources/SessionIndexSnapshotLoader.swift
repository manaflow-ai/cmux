import CmuxAgentSessionStore

/// Explicit executor boundary for the Vault's initial filesystem snapshot.
struct SessionIndexSnapshotLoader: Sendable {
    typealias LoadOperation = @Sendable (any AmpHookSessionReading) async -> [SessionEntry]

    private let loadOperation: LoadOperation

    init() {
        self.loadOperation = { repository in
            await SessionIndexStore.loadInitialEntries(ampSessionRepository: repository)
        }
    }

    init(loadOperation: @escaping @Sendable () async -> [SessionEntry]) {
        self.loadOperation = { _ in await loadOperation() }
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func load(
        ampSessionRepository: any AmpHookSessionReading
    ) async -> [SessionEntry] {
        await loadOperation(ampSessionRepository)
    }
}
