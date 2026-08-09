import Foundation
import os
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

// Pass 2 (impl-B-pass2-wiring) — deferred from Pass 1's own explicit note:
// this needs the mirror actually written from multiple threads under real
// contention, which only becomes meaningful once concurrent writers exist
// (Pass 2's AppKit main-thread writer racing a synthetic second writer
// here stands in for "a queued main-thread task still landing while
// another already ran"). A single-threaded test of `OSAllocatedUnfairLock`
// itself would only re-test the standard library, not this code's actual
// guarantee: every read is one whole, previously-published `publish(_:)`
// call — never a value assembled from two different calls' fields.
@Suite struct HoverCallbackMirrorConcurrencyTests {
    /// Every snapshot two threads can publish, keyed by `hoverEventID` so
    /// a reader can look up which lifetime/eligible/visible combination
    /// SHOULD go with whatever `hoverEventID` it observed. If a torn read
    /// were possible, a reader could observe an `hoverEventID` from one
    /// call paired with `eligible`/`visible` from a different call — which
    /// would fail the lookup below (a genuinely torn value is never a
    /// value equal to ANY whole published snapshot).
    @Test func concurrentWritersNeverProduceATornReadAcrossManyIterations() async throws {
        let lifetimeA = RuntimeSurfaceLifetimeID(surfaceID: UUID(), runtimeSurfaceGeneration: 1)
        let lifetimeB = RuntimeSurfaceLifetimeID(surfaceID: UUID(), runtimeSurfaceGeneration: 2)
        let mirror = HoverCallbackMirror()
        let iterations = 20_000

        // One fixed, closed set of whole snapshots writers ever publish —
        // built so every field combination is otherwise ambiguous (both
        // writers alternate the SAME `hoverEventID` range with DIFFERENT
        // lifetime/eligible/visible triples), so a torn read mixing two
        // calls' fields would very likely produce a combination outside
        // this set rather than coincidentally landing back inside it.
        func snapshotA(_ event: UInt64) -> HoverCallbackSnapshot {
            .init(lifetimeID: lifetimeA, hoverEventID: event, eligible: true, visible: true)
        }
        func snapshotB(_ event: UInt64) -> HoverCallbackSnapshot {
            .init(lifetimeID: lifetimeB, hoverEventID: event, eligible: false, visible: false)
        }
        // The pristine value before either writer's first `publish(_:)`
        // call is itself a legitimate whole (untorn) value — never
        // produced by mixing fields from two different `publish` calls —
        // so a reader observing it early is not a torn read either.
        let pristine = HoverCallbackSnapshot()

        let observedTornRead = OSAllocatedUnfairLock(initialState: false)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for event in 0..<UInt64(iterations) {
                    mirror.publish(snapshotA(event))
                }
            }
            group.addTask {
                for event in 0..<UInt64(iterations) {
                    mirror.publish(snapshotB(event))
                }
            }
            group.addTask {
                for _ in 0..<iterations {
                    let snapshot = mirror.captureHoverCallbackSnapshot()
                    guard snapshot.hoverEventID < UInt64(iterations) else { continue }
                    let matchesA = snapshot == snapshotA(snapshot.hoverEventID)
                    let matchesB = snapshot == snapshotB(snapshot.hoverEventID)
                    let matchesPristine = snapshot == pristine
                    if !matchesA && !matchesB && !matchesPristine {
                        observedTornRead.withLock { $0 = true }
                    }
                }
            }
        }

        #expect(!observedTornRead.withLock { $0 }, "observed a snapshot matching neither writer's whole published value")
    }
}
