import Testing
@testable import CmuxFoundation

@Suite
struct AtomicUInt64ValueTests {
    @Test func storesAndIncrements() {
        let value = AtomicUInt64Value(41)

        #expect(value.loadRelaxed() == 41)
        value.storeRelaxed(7)
        #expect(value.loadRelaxed() == 7)
        #expect(value.wrappingIncrementRelaxed() == 8)
        #expect(value.loadRelaxed() == 8)
    }

    @Test func concurrentIncrementsAreNotLost() async {
        let value = AtomicUInt64Value()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = value.wrappingIncrementRelaxed()
                }
            }
        }

        #expect(value.loadRelaxed() == 100)
    }
}
