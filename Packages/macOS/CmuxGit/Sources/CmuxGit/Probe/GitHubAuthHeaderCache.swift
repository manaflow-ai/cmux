import Foundation

/// Caches GitHub CLI auth-header resolution for the life of the process.
actor GitHubAuthHeaderCache {
    private let failureBackoffBase: TimeInterval
    private let failureBackoffMaximum: TimeInterval
    private let now: @Sendable () -> Date
    private var cachedHeader: String?
    private var retryAt: Date?
    private var consecutiveFailureCount = 0
    private var preservesFailureCountAcrossResolution = false
    private var cacheGeneration = 0
    private var inFlightResolution: (id: UUID, task: Task<String?, Never>)?

    init(
        failureBackoffBase: TimeInterval = 60,
        failureBackoffMaximum: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.failureBackoffBase = max(0, failureBackoffBase)
        self.failureBackoffMaximum = max(
            self.failureBackoffBase,
            max(0, failureBackoffMaximum)
        )
        self.now = now
    }

    /// Returns the cached header or resolves it once when the cache is empty.
    ///
    /// Successful resolutions have no time-based expiry. Failed resolutions
    /// use an exponential backoff so a blocked approval prompt cannot be
    /// recreated on every sidebar refresh. The resolution task is detached
    /// from the caller so cancelling a refresh does not cancel an approval
    /// flow that is already in progress.
    func header(resolve: @escaping @Sendable () async -> String?) async -> String? {
        let currentTime = now()
        if let cachedHeader {
            return cachedHeader
        }
        if let retryAt, currentTime < retryAt {
            return nil
        }
        if let inFlightResolution {
            return await inFlightResolution.task.value
        }

        let generation = cacheGeneration
        let resolutionID = UUID()
        let resolutionTask = Task.detached(priority: .utility, operation: resolve)
        inFlightResolution = (id: resolutionID, task: resolutionTask)
        let header = await resolutionTask.value

        // ``invalidate(ifMatching:)`` can run while the command is waiting for
        // approval. Do not let that stale result repopulate the cache.
        guard inFlightResolution?.id == resolutionID else {
            return header
        }
        inFlightResolution = nil
        guard generation == cacheGeneration else {
            return header
        }
        if let header, !header.isEmpty {
            cachedHeader = header
            retryAt = nil
            if !preservesFailureCountAcrossResolution {
                consecutiveFailureCount = 0
            }
            preservesFailureCountAcrossResolution = false
        } else {
            consecutiveFailureCount += 1
            retryAt = now().addingTimeInterval(failureDelay)
        }
        return header
    }

    /// Invalidates a cached header after an authenticated request is rejected.
    /// The optional match prevents one request using an older credential from
    /// invalidating a newer credential resolved concurrently.
    func invalidate(ifMatching expectedHeader: String? = nil) {
        if let expectedHeader,
           let cachedHeader,
           cachedHeader != expectedHeader {
            return
        }
        cacheGeneration += 1
        cachedHeader = nil
        retryAt = nil
        preservesFailureCountAcrossResolution = true
    }

    /// Records a failed authenticated request and applies the same backoff as
    /// a failed CLI resolution. This prevents a credential that remains
    /// invalid after one refresh from prompting again on every poll. A missing
    /// cached header is treated as unknown state and fails closed as well.
    func recordFailure(ifMatching expectedHeader: String? = nil) {
        if let expectedHeader,
           let cachedHeader,
           cachedHeader != expectedHeader {
            return
        }
        cacheGeneration += 1
        cachedHeader = nil
        consecutiveFailureCount += 1
        preservesFailureCountAcrossResolution = true
        retryAt = now().addingTimeInterval(failureDelay)
    }

    /// Clears an authentication-failure streak after a request succeeds.
    func recordSuccess(ifMatching expectedHeader: String) {
        guard cachedHeader == nil || cachedHeader == expectedHeader else { return }
        consecutiveFailureCount = 0
        preservesFailureCountAcrossResolution = false
        retryAt = nil
    }

    private var failureDelay: TimeInterval {
        let exponent = min(max(consecutiveFailureCount - 1, 0), 4)
        let multiplier = TimeInterval(1 << exponent)
        return min(failureBackoffBase * multiplier, failureBackoffMaximum)
    }
}
