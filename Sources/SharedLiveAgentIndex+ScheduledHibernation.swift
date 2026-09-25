import Darwin
import Foundation

struct SharedLiveAgentIndexScheduledHibernationSession: Sendable {
    let cachedIndex: RestorableAgentSessionIndex
    let processSnapshotLoader: @Sendable () async -> CmuxTopProcessSnapshot
    let completionGeneration: Int
}

extension SharedLiveAgentIndex {
    nonisolated static let maximumForkExecutableWatchSourceCountCeiling = 64
    private nonisolated static let minimumReservedFileDescriptorCount = 128
    private nonisolated static let rlimInfinity = rlim_t(Int64.max)

    nonisolated static func forkExecutableWatchSourceCountBudget(
        softFileDescriptorLimit explicitSoftLimit: Int? = nil,
        openFileDescriptorCount explicitOpenFileDescriptorCount: Int? = nil,
        pendingReservationCount: Int = 0
    ) -> Int {
        guard let softLimit = forkExecutableWatchSoftFileDescriptorLimit(explicitSoftLimit),
              let openFileDescriptorCount = explicitOpenFileDescriptorCount ?? currentOpenFileDescriptorCount() else {
            return 0
        }
        let availableAfterReserve = forkExecutableWatchAvailableDescriptorCount(
            softFileDescriptorLimit: softLimit,
            openFileDescriptorCount: openFileDescriptorCount,
            pendingReservationCount: pendingReservationCount
        )
        guard availableAfterReserve > 0 else { return 0 }
        let derivedBudget = max(1, availableAfterReserve / 4)
        return min(maximumForkExecutableWatchSourceCountCeiling, derivedBudget)
    }

    nonisolated static func forkExecutableWatchDescriptorReserveIsSatisfied(
        pendingReservationCount: Int,
        softFileDescriptorLimit explicitSoftLimit: Int? = nil,
        openFileDescriptorCount explicitOpenFileDescriptorCount: Int? = nil
    ) -> Bool {
        guard let softLimit = forkExecutableWatchSoftFileDescriptorLimit(explicitSoftLimit),
              let openFileDescriptorCount = explicitOpenFileDescriptorCount ?? currentOpenFileDescriptorCount() else {
            return false
        }
        return forkExecutableWatchAvailableDescriptorCount(
            softFileDescriptorLimit: softLimit,
            openFileDescriptorCount: openFileDescriptorCount,
            pendingReservationCount: pendingReservationCount
        ) >= 0
    }

    private nonisolated static func forkExecutableWatchAvailableDescriptorCount(
        softFileDescriptorLimit: Int,
        openFileDescriptorCount: Int,
        pendingReservationCount: Int
    ) -> Int {
        softFileDescriptorLimit - openFileDescriptorCount - pendingReservationCount
            - minimumReservedFileDescriptorCount
    }

    private nonisolated static func forkExecutableWatchSoftFileDescriptorLimit(
        _ explicitSoftLimit: Int?
    ) -> Int? {
        if let explicitSoftLimit { return explicitSoftLimit }
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0,
              limit.rlim_cur != rlimInfinity,
              limit.rlim_cur <= rlim_t(Int.max) else { return nil }
        return Int(limit.rlim_cur)
    }

    private nonisolated static func currentOpenFileDescriptorCount() -> Int? {
        guard let fileDescriptorNames = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return nil
        }
        return fileDescriptorNames.compactMap(Int.init).count
    }
}

extension SharedLiveAgentIndex {
    /// Revalidates the event-driven hook index against one fresh process census.
    ///
    /// Scheduled hibernation does not need to reread every hook store and
    /// transcript every 30 seconds. A hook-store event starts the normal full
    /// reload; in between events this path refreshes only process/liveness
    /// evidence. The cached index is never published over a newer event-driven
    /// reload that raced this census.
    func indexForScheduledHibernation() async -> RestorableAgentSessionIndex? {
        guard let session = beginScheduledHibernationRefresh() else {
            return await indexRefreshingNow()
        }
        let processSnapshot = await session.processSnapshotLoader()
        guard processSnapshot.captureIsAvailable,
              processSnapshot.enumerationIsComplete,
              !Task.isCancelled else {
            return nil
        }
        let refreshedIndex = await Task.detached(priority: .utility) {
            session.cachedIndex.revalidatingCachedProcesses(against: processSnapshot)
        }.value
        guard finishScheduledHibernationRefresh(session, refreshedIndex: refreshedIndex) else {
            return await indexRefreshingNow()
        }
        return refreshedIndex
    }
}
