// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct EventRingTests {
    @Test func assignsMonotonicSeqStartingAtOne() {
        let r = EventRing(capacity: 8)
        let s1 = r.append(.rawBytes(Data([1]), seq: 0))
        let s2 = r.append(.rawBytes(Data([2]), seq: 0))
        let s3 = r.append(.rawBytes(Data([3]), seq: 0))
        #expect(s1 == 1)
        #expect(s2 == 2)
        #expect(s3 == 3)
        #expect(r.lastAppendedSeq == 3)
        #expect(r.oldestSeq == 1)
    }

    @Test func dropsOldestOnOverflowAndKeepsMonotonicSeq() {
        let r = EventRing(capacity: 3)
        for i in 1...5 { _ = r.append(.rawBytes(Data([UInt8(i)]), seq: 0)) }
        #expect(r.lastAppendedSeq == 5)
        #expect(r.oldestSeq == 3) // 1,2 dropped, 3..5 remain
        let all = r.drain(after: 0)
        #expect(all.map { $0.0 } == [3, 4, 5])
    }

    @Test func drainAfterInRingReturnsOnlyNewer() {
        let r = EventRing(capacity: 8)
        for i in 1...4 { _ = r.append(.rawBytes(Data([UInt8(i)]), seq: 0)) }
        let slice = r.drain(after: 2)
        #expect(slice.map { $0.0 } == [3, 4])
    }

    @Test func resumeIsBelowOldestFlagsExpiredId() {
        let r = EventRing(capacity: 2)
        for i in 1...5 { _ = r.append(.rawBytes(Data([UInt8(i)]), seq: 0)) }
        #expect(r.oldestSeq == 4)
        #expect(r.resumeIsBelowOldest(2) == true)
        #expect(r.resumeIsBelowOldest(4) == false)
    }

    @Test func emptyRingDrainReturnsNothing() {
        let r = EventRing(capacity: 4)
        #expect(r.drain(after: 0).isEmpty)
        #expect(r.lastAppendedSeq == 0)
        #expect(r.oldestSeq == 0)
    }
}
