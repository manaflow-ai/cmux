/// A last-owner cleanup request with a finite retry budget.
struct NativeSSHControlMasterPendingCleanup {
    let request: NativeSSHControlMasterCleanupRequest
    private(set) var retriesRemaining: Int

    mutating func consumeRetry() -> Bool {
        guard retriesRemaining > 0 else { return false }
        retriesRemaining -= 1
        return true
    }
}
