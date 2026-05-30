// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

/// Integration coverage for the event-level seq gap invariants in
/// ``EventRing`` (Errata D6).
///
/// ``EventRing`` is the per-subscriber buffer that backs SSE resume.
/// On overflow it drops the oldest entries but the assigned seq keeps
/// climbing — so a client observing a JUMP in `id:` values knows that
/// intermediate events were dropped and it must reconcile by replaying
/// the live tail (or render a synthetic ``: gap`` SSE comment).
///
/// These tests complement ``EventRingTests`` by hammering the four
/// corners that the Phase 2 SSE responder relies on:
///
/// 1. After overflow, ``EventRing/drain(after:)`` of `after=0` returns
///    only the surviving tail with a visible seq gap.
/// 2. ``EventRing/drain(after:)`` of an in-ring boundary returns only
///    newer entries.
/// 3. ``EventRing/drain(after:)`` of a seq above the highest appended
///    is a no-op (the client is already ahead).
/// 4. A capacity-1 ring collapses to a "latest only" view that still
///    keeps the monotonic seq counter intact.
@Suite struct EventRingSeqGapTests {
    /// Capacity-3 ring with 5 appends: oldest two are dropped, but the
    /// surviving entries carry seq=3,4,5 — a JUMP from 0 to 3 that the
    /// SSE layer translates into a `: gap` comment per D6.
    @Test func overflowExposesEventLevelSeqGap() {
        let ring = EventRing(capacity: 3)
        for i in 1...5 {
            _ = ring.append(.rawBytes(Data([UInt8(i)]), seq: 0))
        }
        #expect(ring.oldestSeq == 3)
        #expect(ring.lastAppendedSeq == 5)

        let drained = ring.drain(after: 0)
        #expect(drained.map { $0.0 } == [3, 4, 5],
                "drain(after:0) on an overflowed ring must skip the dropped seq=1,2")
        // The bytes inside the surviving events line up with the
        // matching seq values — proves seq normalization replaced the
        // caller-supplied zero with the assigned monotonic value.
        let bytes = drained.compactMap { (_, ev) -> UInt8? in
            if case .rawBytes(let d, _) = ev { return d.first }
            return nil
        }
        #expect(bytes == [3, 4, 5])
    }

    /// drain(after:4) on a capacity-3 ring filled with 5 events must
    /// return only the last event with seq=5.
    @Test func drainAfterFourReturnsOnlySeqFive() {
        let ring = EventRing(capacity: 3)
        for i in 1...5 {
            _ = ring.append(.rawBytes(Data([UInt8(i)]), seq: 0))
        }
        let drained = ring.drain(after: 4)
        #expect(drained.map { $0.0 } == [5])
    }

    /// drain(after:100) on a ring whose highest seq is 5 must return
    /// nothing — the client is already past every event in the ring.
    @Test func drainAfterAboveHighestReturnsEmpty() {
        let ring = EventRing(capacity: 3)
        for i in 1...5 {
            _ = ring.append(.rawBytes(Data([UInt8(i)]), seq: 0))
        }
        let drained = ring.drain(after: 100)
        #expect(drained.isEmpty)
    }

    /// A capacity-1 ring collapses to "latest only" after many appends,
    /// but the assigned seq counter is still monotonic and reflects the
    /// total append count. This is the worst-case overflow scenario.
    @Test func capacityOneRingKeepsOnlyLatestButPreservesSeq() {
        let ring = EventRing(capacity: 1)
        for i in 1...10 {
            _ = ring.append(.rawBytes(Data([UInt8(i)]), seq: 0))
        }
        #expect(ring.lastAppendedSeq == 10)
        #expect(ring.oldestSeq == 10)
        let drained = ring.drain(after: 0)
        #expect(drained.count == 1)
        #expect(drained.first?.0 == 10)
        // The lone survivor carries the latest payload (byte=10).
        if case .rawBytes(let d, let s) = drained.first!.1 {
            #expect(s == 10)
            #expect(d == Data([10]))
        } else {
            Issue.record("expected rawBytes survivor")
        }
    }

    /// resumeIsBelowOldest agrees with the public seq invariants — a
    /// resume id below ``oldestSeq`` is "expired" and the SSE layer
    /// must emit a synthetic gap comment.
    @Test func resumeIsBelowOldestTracksOverflow() {
        let ring = EventRing(capacity: 3)
        for i in 1...5 {
            _ = ring.append(.rawBytes(Data([UInt8(i)]), seq: 0))
        }
        // oldest=3, latest=5
        #expect(ring.resumeIsBelowOldest(0))
        #expect(ring.resumeIsBelowOldest(2))
        #expect(!ring.resumeIsBelowOldest(3))
        #expect(!ring.resumeIsBelowOldest(5))
    }
}
