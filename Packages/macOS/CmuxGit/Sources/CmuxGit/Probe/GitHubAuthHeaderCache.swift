import Foundation

/// Caches GitHub auth-header resolution for the life of the process.
actor GitHubAuthHeaderCache {
    private let failureBackoffBase: TimeInterval
    private let failureBackoffMaximum: TimeInterval
    private let now: @Sendable () -> Date
    private var cachedLease: GitHubAuthHeaderLease?
    private var retryAt: Date?
    private var consecutiveFailureCount = 0
    private var preservesFailureCountAcrossResolution = false
    private var stateGeneration: UInt64 = 0
    private var credentialGeneration: UInt64 = 0
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

    /// Returns the current lease or resolves one when the cache is empty.
    ///
    /// Successful resolutions have no time-based expiry. Failed resolutions
    /// use an exponential backoff so a blocked approval prompt cannot be
    /// recreated on every sidebar refresh. The resolution task is detached
    /// from the caller so cancelling a refresh does not cancel an approval
    /// flow that is already in progress.
    func header(resolve: @escaping @Sendable () async -> String?) async -> GitHubAuthHeaderLease? {
        while true {
            let currentTime = now()
            if let cachedLease {
                return cachedLease
            }
            if let retryAt, currentTime < retryAt {
                return nil
            }
            if let inFlightResolution {
                _ = await inFlightResolution.task.value
                continue
            }

            let resolutionStateGeneration = stateGeneration
            let resolutionID = UUID()
            let resolutionTask = Task.detached(priority: .utility, operation: resolve)
            inFlightResolution = (id: resolutionID, task: resolutionTask)
            let header = await resolutionTask.value

            // Invalidation can run while the command is waiting for approval.
            // Discard that stale result and let the loop observe the current
            // credential/backoff state instead of handing out an obsolete lease.
            guard inFlightResolution?.id == resolutionID else {
                continue
            }
            inFlightResolution = nil
            guard resolutionStateGeneration == stateGeneration else {
                continue
            }
            if let header, !header.isEmpty {
                credentialGeneration &+= 1
                let lease = GitHubAuthHeaderLease(
                    value: header,
                    generation: credentialGeneration
                )
                cachedLease = lease
                retryAt = nil
                if !preservesFailureCountAcrossResolution {
                    consecutiveFailureCount = 0
                }
                preservesFailureCountAcrossResolution = false
                return lease
            }

            consecutiveFailureCount += 1
            retryAt = now().addingTimeInterval(failureDelay)
            return nil
        }
    }

    /// Invalidates a lease after an authenticated request is rejected.
    /// Requests carrying an older or unknown lease are ignored.
    func invalidate(_ lease: GitHubAuthHeaderLease) {
        guard cachedLease == lease else { return }
        stateGeneration &+= 1
        cachedLease = nil
        retryAt = nil
        preservesFailureCountAcrossResolution = true
    }

    /// Records a failed authenticated request and applies exponential backoff.
    /// Only the currently authoritative lease may advance the failure streak.
    func recordFailure(_ lease: GitHubAuthHeaderLease) {
        guard cachedLease == lease else { return }
        stateGeneration &+= 1
        cachedLease = nil
        consecutiveFailureCount += 1
        preservesFailureCountAcrossResolution = true
        retryAt = now().addingTimeInterval(failureDelay)
    }

    /// Clears an authentication-failure streak after the current lease succeeds.
    func recordSuccess(_ lease: GitHubAuthHeaderLease) {
        // An empty cache or a different generation is an unknown/rejected
        // state. A delayed response from an older request must not clear it.
        guard cachedLease == lease else { return }
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
