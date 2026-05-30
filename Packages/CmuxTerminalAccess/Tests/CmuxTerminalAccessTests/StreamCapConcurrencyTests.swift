// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

/// Concurrency coverage for ``StreamCap`` (D7 + D24).
///
/// ``StreamCapTests`` covers the single-threaded contract. This suite
/// pins the behavior the Phase 2 SSE responder relies on when many SSE
/// clients race to acquire a slot for the same surface:
///
/// 1. Concurrent ``StreamCap/acquire(surface:)`` from N tasks against a
///    cap of K returns exactly K non-nil tokens and (N-K) nils.
/// 2. ``StreamCap/Token/release()`` under concurrent acquire frees its
///    slot promptly so a subsequent acquire succeeds without races
///    leaking the slot.
///
/// Both tests use ``Task.detached`` for the racing tasks and an `actor`
/// counter to safely tally results without locking in test code.
@Suite struct StreamCapConcurrencyTests {
    private let surface: SurfaceHandle = .ref(kind: "surface", ordinal: 1)

    /// 20 concurrent acquires against cap=5 → exactly 5 succeed, 15 fail.
    @Test func concurrentAcquireRespectsCapExactly() async {
        let cap = StreamCap(maxPerSurface: 5)
        let surface = surface
        let tally = AcquireTally()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let token = cap.acquire(surface: surface)
                    if let t = token {
                        await tally.recordSuccess(t)
                    } else {
                        await tally.recordFailure()
                    }
                }
            }
            await group.waitAll()
        }

        let successes = await tally.successCount
        let failures = await tally.failureCount
        #expect(successes == 5, "exactly cap=5 acquires must succeed under contention")
        #expect(failures == 15)
        #expect(cap.openCount(for: surface) == 5)

        // Release every won token; cap must drain to zero.
        await tally.releaseAll()
        #expect(cap.openCount(for: surface) == 0)
    }

    /// A released slot becomes immediately available to a subsequent
    /// acquire from another task. Acquires until cap, releases one,
    /// then races N tasks for the freed slot — exactly one wins.
    @Test func releaseFreesSlotForConcurrentAcquire() async {
        let cap = StreamCap(maxPerSurface: 3)
        let surface = surface
        // Fill the cap.
        let a = cap.acquire(surface: surface)
        let b = cap.acquire(surface: surface)
        let c = cap.acquire(surface: surface)
        #expect(a != nil && b != nil && c != nil)
        #expect(cap.acquire(surface: surface) == nil,
                "all 3 slots used; sanity check")

        // Release one and race 10 tasks for the freed slot. Exactly one
        // should win regardless of scheduler interleaving.
        b?.release()
        let tally = AcquireTally()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    if let t = cap.acquire(surface: surface) {
                        await tally.recordSuccess(t)
                    } else {
                        await tally.recordFailure()
                    }
                }
            }
            await group.waitAll()
        }

        let successes = await tally.successCount
        #expect(successes == 1, "exactly one task wins the released slot")
        #expect(cap.openCount(for: surface) == 3)
        _ = a; _ = c  // keep tokens alive past assertions
        await tally.releaseAll()
        a?.release(); c?.release()
        #expect(cap.openCount(for: surface) == 0)
    }
}

/// Actor that records concurrent acquire/release outcomes for the
/// concurrency tests. Holds successful tokens so they aren't released
/// by deinit mid-test.
private actor AcquireTally {
    private(set) var successCount: Int = 0
    private(set) var failureCount: Int = 0
    private var held: [StreamCap.Token] = []

    func recordSuccess(_ token: StreamCap.Token) {
        successCount += 1
        held.append(token)
    }
    func recordFailure() { failureCount += 1 }
    func releaseAll() {
        for t in held { t.release() }
        held.removeAll()
    }
}

private extension TaskGroup where ChildTaskResult == Void {
    mutating func waitAll() async {
        for await _ in self {}
    }
}
