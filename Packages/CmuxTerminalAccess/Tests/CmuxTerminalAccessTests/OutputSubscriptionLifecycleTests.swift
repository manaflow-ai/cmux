// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

/// Lifecycle coverage for ``OutputSubscription`` (D22).
///
/// ``OutputSubscriptionTests`` covers the basic cancel/end fire-once
/// invariants. This suite pins the full lifecycle that the Phase 2 SSE
/// responder relies on:
///
/// 1. ``OutputSubscription/events()`` yields written events in order
///    and the embedded seq values stay monotonically increasing.
/// 2. ``OutputSubscription/signalEnd()`` finishes the async stream
///    cleanly and fires ``OutputSubscription/onEnd`` exactly once even
///    if called multiple times.
/// 3. ``OutputSubscription/cancel()`` finishes the stream and subsequent
///    ``OutputSubscription/yield(_:)`` calls are no-ops, not crashes.
/// 4. ``OutputSubscription/attachRingOldestSeq(_:)`` reflects the live
///    ring's oldest seq across overflow.
@Suite struct OutputSubscriptionLifecycleTests {
    /// AsyncStream drains events in append order with monotonic seq.
    @Test func eventsStreamYieldsInOrderWithMonotonicSeq() async {
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw, onCancel: {}
        )
        let stream = sub.events()
        // 6 events with synthetic seq=1..6.
        for i in UInt64(1)...6 {
            sub.yield(.rawBytes(Data([UInt8(i)]), seq: i))
        }
        sub.finish()
        var seen: [UInt64] = []
        var payloads: [UInt8] = []
        for await ev in stream {
            if case .rawBytes(let d, let s) = ev {
                seen.append(s)
                if let b = d.first { payloads.append(b) }
            }
        }
        #expect(seen == [1, 2, 3, 4, 5, 6])
        #expect(payloads == [1, 2, 3, 4, 5, 6])
        // Monotonic invariant — stronger than equality with the literal.
        #expect(seen == seen.sorted())
        #expect(Set(seen).count == seen.count, "seq values must be unique")
    }

    /// signalEnd() finishes the stream and fires onEnd exactly once even
    /// if signalEnd is called multiple times.
    @Test func signalEndFinishesStreamAndFiresOnEndExactlyOnce() async {
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .cells, onCancel: {}
        )
        let lock = NSLock()
        nonisolated(unsafe) var endHits = 0
        sub.onEnd = { lock.lock(); endHits += 1; lock.unlock() }
        let stream = sub.events()
        sub.yield(.gap(seq: 1))
        // Multiple signalEnd calls; only the first should fire onEnd.
        sub.signalEnd()
        sub.signalEnd()
        sub.signalEnd()
        var drained: [OutputEvent] = []
        for await ev in stream { drained.append(ev) }
        // Stream finished cleanly.
        #expect(drained.count == 1)
        if case .gap(let s) = drained[0] {
            #expect(s == 1)
        } else {
            Issue.record("expected gap event")
        }
        lock.lock(); let hits = endHits; lock.unlock()
        #expect(hits == 1, "onEnd must fire exactly once across N signalEnd calls")
    }

    /// cancel() finishes the stream as cancelled and subsequent yields
    /// are silently dropped (no crash).
    @Test func cancelFinishesStreamAndPostCancelYieldsAreSilent() async {
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw, onCancel: {}
        )
        let stream = sub.events()
        sub.yield(.rawBytes(Data([0xAA]), seq: 1))
        sub.cancel()
        // These three must NOT crash — yield is a no-op after cancel.
        sub.yield(.rawBytes(Data([0xBB]), seq: 2))
        sub.yield(.rawBytes(Data([0xCC]), seq: 3))
        sub.yield(.gap(seq: 4))

        var drained: [UInt64] = []
        for await ev in stream {
            if case .rawBytes(_, let s) = ev { drained.append(s) }
        }
        // We may or may not see the pre-cancel yield depending on the
        // dispatch of cancel() relative to the AsyncStream buffer; what
        // matters is that no post-cancel event leaks through.
        #expect(!drained.contains(2))
        #expect(!drained.contains(3))
        #expect(!drained.contains(4))
    }

    /// attachRingOldestSeq exposes the LIVE oldest seq value, so the
    /// SSE layer's gap-comment decision tracks the ring through
    /// overflow without re-attaching the provider closure.
    @Test func attachRingOldestSeqReturnsLiveRingValue() {
        let ring = EventRing(capacity: 3)
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .cells, onCancel: {}
        )
        sub.attachRingOldestSeq { [weak ring] in ring?.oldestSeq ?? 0 }

        // Empty ring → 0 (caller treats as "ring is empty, no gap needed").
        #expect(sub.ringOldestSeq() == 0)

        for i in 1...2 {
            _ = ring.append(.rawBytes(Data([UInt8(i)]), seq: 0))
        }
        #expect(sub.ringOldestSeq() == 1)

        // Overflow — capacity-3 ring after 5 appends has oldest=3.
        for i in 3...5 {
            _ = ring.append(.rawBytes(Data([UInt8(i)]), seq: 0))
        }
        #expect(sub.ringOldestSeq() == 3)

        // Continued overflow tracks live state.
        for i in 6...8 {
            _ = ring.append(.rawBytes(Data([UInt8(i)]), seq: 0))
        }
        #expect(sub.ringOldestSeq() == 6)
    }

    /// When no provider is attached, ringOldestSeq() returns 0 — that's
    /// the documented "no provider / ring empty" sentinel.
    @Test func ringOldestSeqReturnsZeroWhenNoProviderAttached() {
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .cells, onCancel: {}
        )
        #expect(sub.ringOldestSeq() == 0)
    }
}
