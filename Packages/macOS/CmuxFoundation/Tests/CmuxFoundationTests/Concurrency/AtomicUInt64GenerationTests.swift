import Testing
@testable import CmuxFoundation

@Suite
struct AtomicUInt64GenerationTests {
    @Test func advancesSequentiallyFromInjectedInitialValue() {
        let generation = AtomicUInt64Generation(41)

        #expect(generation.loadRelaxed() == 41)
        #expect(generation.advanceRelaxed() == 42)
        #expect(generation.loadRelaxed() == 42)
    }

    @Test func concurrentAdvancesReturnUniqueMonotonicIdentities() async {
        let generation = AtomicUInt64Generation()
        let values = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in 0..<100 {
                group.addTask { generation.advanceRelaxed() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(Set(values).count == 100)
        #expect(values.min() == 1)
        #expect(values.max() == 100)
        #expect(generation.loadRelaxed() == 100)
    }

    @Test func saturationPreservesMonotonicIdentity() {
        let generation = AtomicUInt64Generation(UInt64.max - 1)

        #expect(generation.advanceRelaxed() == UInt64.max)
        #expect(generation.advanceRelaxed() == UInt64.max)
        #expect(generation.loadRelaxed() == UInt64.max)
    }
}
