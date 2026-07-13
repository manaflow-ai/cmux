import Foundation
import os

private nonisolated struct CmuxTopProcessSnapshotCacheState {
    var snapshot: CmuxTopProcessSnapshot?
    var includeProcessDetails = false
    var includeCMUXScope = true
}

// libproc snapshots are a short-lived platform bridge shared by the CLI, socket,
// and Task Manager paths; keep the cache here so ownership stays with capture().
private nonisolated let cmuxTopProcessSnapshotCache = OSAllocatedUnfairLock(
    initialState: CmuxTopProcessSnapshotCacheState()
)

nonisolated extension CmuxTopProcessSnapshot {
    static func captureCached(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true,
        maximumAge: TimeInterval
    ) -> CmuxTopProcessSnapshot {
        let now = Date()
        if let cached = cmuxTopProcessSnapshotCache.withLock({ state -> CmuxTopProcessSnapshot? in
            guard let snapshot = state.snapshot,
                  Self.cachedSnapshotDetailsSatisfy(
                      state.includeProcessDetails,
                      requested: includeProcessDetails
                  ),
                  Self.cachedSnapshotCMUXScopeSatisfies(
                      state.includeCMUXScope,
                      requested: includeCMUXScope
                  ),
                  now.timeIntervalSince(snapshot.sampledAt) <= maximumAge else {
                return nil
            }
            return snapshot
        }) {
            return cached
        }

        let snapshot = capture(
            includeProcessDetails: includeProcessDetails,
            includeCMUXScope: includeCMUXScope
        )
        return cmuxTopProcessSnapshotCache.withLock { state in
            let storeTime = Date()
            if let cached = state.snapshot,
               Self.cachedSnapshotDetailsSatisfy(
                   state.includeProcessDetails,
                   requested: includeProcessDetails
               ),
               Self.cachedSnapshotCMUXScopeSatisfies(
                   state.includeCMUXScope,
                   requested: includeCMUXScope
               ),
               storeTime.timeIntervalSince(cached.sampledAt) <= maximumAge {
                return cached
            }
            state.snapshot = snapshot
            state.includeProcessDetails = includeProcessDetails
            state.includeCMUXScope = includeCMUXScope
            return snapshot
        }
    }

    private static func cachedSnapshotDetailsSatisfy(
        _ cachedIncludesProcessDetails: Bool,
        requested: Bool
    ) -> Bool {
        cachedIncludesProcessDetails || !requested
    }

    private static func cachedSnapshotCMUXScopeSatisfies(
        _ cachedIncludesCMUXScope: Bool,
        requested: Bool
    ) -> Bool {
        cachedIncludesCMUXScope || !requested
    }
}
