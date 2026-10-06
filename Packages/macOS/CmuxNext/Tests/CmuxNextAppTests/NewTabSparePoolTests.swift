import Testing
@testable import CmuxNextApp

/// One spare per window (plans/cmux-next/new-tab.md section 2.2), as a pure
/// slot: warming and parked hand out the spare; an adopt or a drop empties
/// the slot, and only an empty slot starts a new spare.
@Suite struct NewTabSparePoolTests {
    @Test func theSlotHandsOutAtMostOneSpareAndRewarmsOnlyWhenEmpty() {
        var slot = NewTabSpareSlot<Int>()
        #expect(slot.take() == nil)
        #expect(slot.shouldWarm)
        slot.parked(1)
        #expect(!slot.shouldWarm)
        #expect(slot.take() == 1)
        #expect(slot.take() == nil)
        #expect(slot.shouldWarm)
        slot.parked(2)
        #expect(slot.drop() == 2)
        #expect(slot.shouldWarm)
        #expect(slot.drop() == nil)
    }

    /// Any sequence of events keeps at most one spare and never hands out
    /// the same spare twice.
    @Test func noEventSequenceDuplicatesASpare() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var slot = NewTabSpareSlot<Int>()
            var handedOut: Set<Int> = []
            var next = 0
            for _ in 0..<40 {
                switch Int.random(in: 0..<3, using: &generator) {
                case 0 where slot.shouldWarm:
                    next += 1
                    slot.parked(next)
                case 1:
                    if let spare = slot.take() { #expect(handedOut.insert(spare).inserted) }
                default:
                    if let spare = slot.drop() { #expect(!handedOut.contains(spare)) }
                }
                #expect(slot.count <= 1)
            }
        }
    }
}
