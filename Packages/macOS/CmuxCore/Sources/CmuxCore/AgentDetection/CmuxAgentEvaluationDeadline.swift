import Darwin

/// A synchronous CPU-time budget shared by regexes in one detection request.
struct CmuxAgentEvaluationDeadline: Sendable {
    /// Keeps a future live reconciliation pass comfortably below one frame
    /// even when a user-authored rule makes ICU backtrack. Thread CPU time is
    /// used so scheduler preemption cannot turn a cheap rule into a false
    /// negative.
    private static let maximumCPUTimeNanoseconds: UInt64 = 10_000_000

    private let startingThreadCPUTimeNanoseconds: UInt64

    init() {
        self.startingThreadCPUTimeNanoseconds = clock_gettime_nsec_np(
            CLOCK_THREAD_CPUTIME_ID
        )
    }

    var isExceeded: Bool {
        let current = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        guard current >= startingThreadCPUTimeNanoseconds else { return false }
        return current - startingThreadCPUTimeNanoseconds
            >= Self.maximumCPUTimeNanoseconds
    }
}
