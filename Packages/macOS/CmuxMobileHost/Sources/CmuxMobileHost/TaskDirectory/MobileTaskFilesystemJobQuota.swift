import os

/// Admits a bounded number of mobile task filesystem jobs without queueing
/// additional work when the host is already saturated.
public final class MobileTaskFilesystemJobQuota: Sendable {
    private let maximumConcurrentJobs: Int
    // lint:allow lock - async handlers need synchronous fail-fast admission
    // and synchronous `defer` release so cancellation cannot leak capacity.
    private let inFlightJobs = OSAllocatedUnfairLock(initialState: 0)

    public init(maximumConcurrentJobs: Int = 2) {
        precondition(maximumConcurrentJobs > 0)
        self.maximumConcurrentJobs = maximumConcurrentJobs
    }

    /// Reserves one filesystem job slot without waiting for capacity.
    public func acquire() -> Bool {
        inFlightJobs.withLock { inFlightJobs in
            guard inFlightJobs < maximumConcurrentJobs else { return false }
            inFlightJobs += 1
            return true
        }
    }

    /// Releases one slot returned by a successful ``acquire()``.
    public func release() {
        inFlightJobs.withLock { inFlightJobs in
            precondition(inFlightJobs > 0, "release without a matching acquire")
            inFlightJobs -= 1
        }
    }
}
