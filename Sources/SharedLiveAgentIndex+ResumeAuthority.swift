import Foundation

extension SharedLiveAgentIndex {
    /// Returns combined indexes from a generation whose physical capture starts after this request.
    func resumeIndexesCapturedAfterRequest() async -> ProcessDetectedResumeIndexes? {
        ensureWatchingHookStoreDirectory()
        let task = requestRefresh(
            freshness: .captureAfterRequest,
            publication: .scoped,
            validating: nil
        )
        guard let result = await task.value else { return nil }
        return ProcessDetectedResumeIndexes(result)
    }

    /// Returns a recent combined result, joins the active generation, or starts one when stale.
    func resumeIndexesRefreshingIfNeeded(
        maximumAge: TimeInterval = 60
    ) async -> ProcessDetectedResumeIndexes? {
        ensureWatchingHookStoreDirectory()
        while true {
            if refreshTailID != nil {
                let task = requestRefresh(
                    freshness: .joinCurrentGeneration,
                    publication: .scoped,
                    validating: nil
                )
                return await task.value.map(ProcessDetectedResumeIndexes.init)
            }
            guard case .some = latestCompletedLoadResult,
                  let latestCompletedAt,
                  dateProvider().timeIntervalSince(latestCompletedAt) < maximumAge else {
                break
            }
            guard let currentResult = latestCompletedLoadResult else { continue }
            let validatedOrdinal = latestCompletedOrdinal
            let validatedRevision = resumeAuthorityRevision
            let validationTask = requestRefresh(
                freshness: .joinCurrentGeneration,
                publication: .scoped,
                validating: nil,
                cachedResultToValidate: currentResult
            )
            guard let validatedResult = await validationTask.value else {
                if latestCompletedOrdinal > validatedOrdinal,
                   latestCompletedLoadResult != nil {
                    continue
                }
                if resumeAuthorityRevision == validatedRevision,
                   latestCompletedLoadResult != nil {
                    invalidateAllCachedResults()
                }
                return nil
            }
            guard refreshTailID == nil else { continue }
            return ProcessDetectedResumeIndexes(validatedResult)
        }
        let task = requestRefresh(
            freshness: .joinCurrentGeneration,
            publication: .scoped,
            validating: nil
        )
        if let result = await task.value {
            return ProcessDetectedResumeIndexes(result)
        }
        return nil
    }

    /// Returns the newest completed coordinated capture immediately on the main actor.
    func cachedResumeIndexes() -> ProcessDetectedResumeIndexes? {
        latestCompletedLoadResult.map(ProcessDetectedResumeIndexes.init)
    }

    /// Returns the newest completed coordinated capture and schedules a refresh if stale.
    func currentResumeIndexesSchedulingRefresh() -> ProcessDetectedResumeIndexes? {
        scheduleRefreshIfStale()
        return cachedResumeIndexes()
    }
}
