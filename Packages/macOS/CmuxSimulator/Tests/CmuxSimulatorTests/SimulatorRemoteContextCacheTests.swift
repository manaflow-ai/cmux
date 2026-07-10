import Testing
@testable import CmuxSimulator

@Suite("Simulator remote context cache")
struct SimulatorRemoteContextCacheTests {
    @Test("An older asynchronous update cannot replace a newer remote context")
    @MainActor
    func rejectsOutOfOrderContextUpdates() {
        let cache = SimulatorRemoteContextCache()

        cache.update(contextID: 42, revision: 2)
        cache.update(contextID: 7, revision: 1)

        #expect(cache.contextID == 42)
    }
}
