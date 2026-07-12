extension AgentSyncEngine {
    /// Cancels the current backoff and retries reconciliation immediately.
    public func retryNow() {
        retryTask?.cancel()
        retryTask = nil
        triggerResync()
    }
}
