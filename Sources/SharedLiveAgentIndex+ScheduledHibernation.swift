import Foundation

extension SharedLiveAgentIndex {
    /// Revalidates the event-driven hook index against one fresh process census.
    ///
    /// Scheduled hibernation does not need to reread every hook store and
    /// transcript every 30 seconds. A hook-store event starts the normal full
    /// reload; in between events this path refreshes only process/liveness
    /// evidence. The cached index is never published over a newer event-driven
    /// reload that raced this census.
    func indexForScheduledHibernation() async -> RestorableAgentSessionIndex? {
        ensureWatchingHookStoreDirectory()
        guard let cachedIndex = index else {
            return await indexRefreshingNow()
        }
        let processSnapshot = await processSnapshotLoader()
        guard processSnapshot.captureIsAvailable,
              processSnapshot.enumerationIsComplete,
              !Task.isCancelled else {
            return nil
        }
        let capturedCompletionGeneration = refreshCompletionGeneration
        let refreshedIndex = await Task.detached(priority: .utility) {
            cachedIndex.revalidatingCachedProcesses(against: processSnapshot)
        }.value
        guard !Task.isCancelled,
              refreshCompletionGeneration == capturedCompletionGeneration,
              refreshTask == nil,
              forkAvailabilityRefreshTask == nil else {
            return await indexRefreshingNow()
        }
        let previousFingerprint = liveAgentProcessFingerprint
        index = refreshedIndex
        loadedAt = dateProvider()
        liveAgentProcessFingerprint = refreshedIndex.liveAgentProcessFingerprint()
            .union(refreshedIndex.liveSessionOwnerFingerprint)
        if liveAgentProcessFingerprint != previousFingerprint {
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
        }
        return refreshedIndex
    }
}
