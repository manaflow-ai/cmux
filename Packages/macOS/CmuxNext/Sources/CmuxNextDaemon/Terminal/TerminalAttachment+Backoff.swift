import CmuxNextWakeups

extension TerminalAttachment {
    /// Backoff before the `failed + 1`th re-attach in a row, 30 s after 8 doublings: spaces the view's own
    /// retries and the event-started ones after them. A view turned off by its organization stops after it (the caller).
    public nonisolated static func reattachBackoff(afterFailures failed: Int) async throws {
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        for _ in 1..<min(max(1, failed), 8) { _ = backoff.next() }
        // concurrency-allow: async sleep on the attach task, only before a re-attach that follows a failed one
        try await backoff.wait(owner: "terminal.reattach")
    }
}
