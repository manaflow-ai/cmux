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

    @Test func boundedClaimsAndReleasesPreserveTheLimit() {
        let value = AtomicUInt64Value()

        #expect(value.incrementIfBelow(2))
        #expect(value.incrementIfBelow(2))
        #expect(!value.incrementIfBelow(2))
        #expect(value.loadRelaxed() == 2)
        #expect(value.decrementIfPositive())
        #expect(value.incrementIfBelow(2))
        #expect(value.decrementIfPositive())
        #expect(value.decrementIfPositive())
        #expect(!value.decrementIfPositive())
        #expect(value.loadRelaxed() == 0)
    }

    @Test func concurrentBoundedClaimsNeverExceedTheLimit() async {
        let value = AtomicUInt64Value()
        let claims = await withTaskGroup(
            of: Bool.self,
            returning: [Bool].self
        ) { group in
            for _ in 0..<100 {
                group.addTask {
                    value.incrementIfBelow(4)
                }
            }
            return await group.reduce(into: []) {
                $0.append($1)
            }
        }

        #expect(claims.filter { $0 }.count == 4)
        #expect(value.loadRelaxed() == 4)
    }
}
