import Testing
@testable import CmuxFoundation

@Suite
struct AtomicBooleanGateTests {
    @Test func publishesTransitionsAcrossConcurrentReaders() async {
        let gate = AtomicBooleanGate(false)
        #expect(!gate.loadRelaxed())

        gate.storeRelease(true)
        let observations = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<100 {
                group.addTask { gate.loadRelaxed() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(observations.allSatisfy { $0 })
        gate.storeRelease(false)
        #expect(!gate.loadRelaxed())
    }

    @Test func concurrentReadersAndWritersShareStableAtomicStorage() async {
        let gate = AtomicBooleanGate(false)

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for iteration in 0..<10_000 {
                        gate.storeRelease((writer + iteration).isMultiple(of: 2))
                    }
                }
            }
            for _ in 0..<32 {
                group.addTask {
                    for _ in 0..<10_000 {
                        _ = gate.loadRelaxed()
                    }
                }
            }
        }

        gate.storeRelease(true)
        #expect(gate.loadRelaxed())
    }

    @Test func acquireReaderObservesReleasePublishedActivation() async {
        let gate = AtomicBooleanGate(false)
        gate.storeRelease(true)

        let observed = await Task.detached {
            gate.loadAcquire()
        }.value

        #expect(observed)
    }

    @Test func compareExchangeClaimsOnlyOneConcurrentCaller() async {
        let gate = AtomicBooleanGate(false)

        let claims = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<100 {
                group.addTask {
                    gate.compareExchange(expected: false, desired: true)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(claims.filter { $0 }.count == 1)
        #expect(gate.loadAcquire())
        #expect(!gate.compareExchange(expected: false, desired: true))
    }
}
