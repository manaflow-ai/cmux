import Foundation
import os

private struct CmuxTopProcessSnapshotSlot {
    var snapshot: CmuxTopProcessSnapshot?
    var includeProcessDetails = false
    var includeCMUXScope = true
}

private struct CmuxTopProcessSnapshotCacheState {
    // One slot per detail level: the pane-memory guardrail's frequent no-details
    // captures and the agent-index/autosave detailed captures used to share a
    // single slot and evicted each other, so interleaved consumers each paid a
    // full libproc enumeration. Detailed snapshots satisfy no-details requests,
    // so keeping both levels warm collapses the steady state to roughly one
    // detailed capture per freshness window.
    var detailed = CmuxTopProcessSnapshotSlot()
    var basic = CmuxTopProcessSnapshotSlot()
}

// libproc snapshots are a short-lived platform bridge shared by the CLI, socket,
// and Task Manager paths; keep the cache here so ownership stays with capture().
private nonisolated let cmuxTopProcessSnapshotCache = OSAllocatedUnfairLock(
    initialState: CmuxTopProcessSnapshotCacheState()
)

extension CmuxTopProcessSnapshot {
    static func captureCached(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true,
        maximumAge: TimeInterval
    ) -> CmuxTopProcessSnapshot {
        let now = Date()
        if let cached = cmuxTopProcessSnapshotCache.withLock({ state in
            state.satisfyingSnapshot(
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope,
                maximumAge: maximumAge,
                now: now
            )
        }) {
            return cached
        }

        let snapshot = capture(
            includeProcessDetails: includeProcessDetails,
            includeCMUXScope: includeCMUXScope
        )
        return cmuxTopProcessSnapshotCache.withLock { state in
            // A concurrent caller may have stored a satisfying snapshot while this
            // capture ran; keep every caller on that one instead of publishing two.
            if let cached = state.satisfyingSnapshot(
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope,
                maximumAge: maximumAge,
                now: Date()
            ) {
                return cached
            }
            let slot = CmuxTopProcessSnapshotSlot(
                snapshot: snapshot,
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope
            )
            if includeProcessDetails {
                state.detailed = slot
            } else {
                state.basic = slot
            }
            return snapshot
        }
    }
}

extension CmuxTopProcessSnapshotCacheState {
    fileprivate func satisfyingSnapshot(
        includeProcessDetails: Bool,
        includeCMUXScope: Bool,
        maximumAge: TimeInterval,
        now: Date
    ) -> CmuxTopProcessSnapshot? {
        let candidates = [detailed, basic]
        var best: CmuxTopProcessSnapshot?
        for slot in candidates {
            guard let snapshot = slot.snapshot,
                  slot.includeProcessDetails || !includeProcessDetails,
                  slot.includeCMUXScope || !includeCMUXScope,
                  now.timeIntervalSince(snapshot.sampledAt) <= maximumAge else {
                continue
            }
            if let current = best, current.sampledAt >= snapshot.sampledAt {
                continue
            }
            best = snapshot
        }
        return best
    }
}
