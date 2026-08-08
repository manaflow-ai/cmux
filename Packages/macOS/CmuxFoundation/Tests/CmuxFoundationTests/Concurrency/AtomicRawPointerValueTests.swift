import Testing
@testable import CmuxFoundation

@Suite
struct AtomicRawPointerValueTests {
    @Test func compareExchangeOnlyReplacesTheExpectedPointer() {
        let first = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let second = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            first.deallocate()
            second.deallocate()
        }
        let value = AtomicRawPointerValue()

        #expect(value.loadAcquire() == nil)
        #expect(value.compareExchange(expected: nil, desired: first))
        #expect(value.loadAcquire() == UnsafeRawPointer(first))
        #expect(!value.compareExchange(expected: nil, desired: second))
        #expect(value.compareExchange(expected: first, desired: second))
        #expect(value.loadAcquire() == UnsafeRawPointer(second))
    }
}
