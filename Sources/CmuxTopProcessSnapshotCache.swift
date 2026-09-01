import Foundation
import os

private struct CmuxTopProcessSnapshotCacheState {
    var snapshot: CmuxTopProcessSnapshot?
    var includeProcessDetails = false
    var includeCMUXScope = true
    var includeOwnershipDetails = false
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
        includeOwnershipDetails: Bool = false,
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
                  Self.cachedSnapshotOwnershipDetailsSatisfy(
                      state.includeOwnershipDetails,
                      requested: includeOwnershipDetails
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
            includeCMUXScope: includeCMUXScope,
            includeOwnershipDetails: includeOwnershipDetails
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
               Self.cachedSnapshotOwnershipDetailsSatisfy(
                   state.includeOwnershipDetails,
                   requested: includeOwnershipDetails
               ),
               storeTime.timeIntervalSince(cached.sampledAt) <= maximumAge {
                return cached
            }
            state.snapshot = snapshot
            state.includeProcessDetails = includeProcessDetails
            state.includeCMUXScope = includeCMUXScope
            state.includeOwnershipDetails = includeOwnershipDetails
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

    /// Returns whether a cached snapshot contains the requested ownership paths.
    private static func cachedSnapshotOwnershipDetailsSatisfy(
        _ cachedIncludesOwnershipDetails: Bool,
        requested: Bool
    ) -> Bool {
        cachedIncludesOwnershipDetails || !requested
    }
}
