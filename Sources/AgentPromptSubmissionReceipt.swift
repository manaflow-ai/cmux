import Foundation

/// One-shot synchronous bridge for the socket worker that owns the RPC reply.
///
/// There is intentionally no timeout: timing out while leaving a queued prompt
/// live would make the result ambiguous and a caller retry could duplicate the
/// message. Delivery only awaits the app-owned FIFO and one bounded main-actor
/// terminal transaction, matching the control socket's existing synchronous
/// main-hop semantics.
///
/// `@unchecked Sendable` is safe here because `condition` protects every read
/// and write of the one-shot `result`; no mutable state escapes the type.
nonisolated final class AgentPromptSubmissionReceipt: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: AgentPromptSubmissionResult?

    /// Publishes the receipt's single terminal result.
    func complete(with result: AgentPromptSubmissionResult) {
        condition.lock()
        precondition(self.result == nil, "Agent prompt receipt completed twice")
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks the socket worker until the definitive result is published.
    func wait() -> AgentPromptSubmissionResult {
        condition.lock()
        while result == nil {
            condition.wait()
        }
        let completed = result!
        condition.unlock()
        return completed
    }
}
