public import Foundation

extension Task where Success == Result<[String: ActionResultValue], ActionWorkFailure>, Failure == Never {
    /// This work's answer if it comes within `wait`, else nil (the work keeps running): an action run that answers
    /// `pending` past its wait (CloudHandlers.result). Both sides yield into one stream and the first value wins:
    /// awaiting an unstructured task's `value` ignores cancellation, so a task group racing it would wait for the work
    /// to end anyway. The stream keeps only the first of its two values.
    public func firstAnswer(within wait: Duration) async -> Success? {
        let (answers, continuation) = AsyncStream<Success?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // task-owner: relays the work's answer; it ends with the work (a yield after finish is dropped).
        Task<Void, Never> { continuation.yield(await self.value) }
        // task-owner: the answer deadline; cancelled below once an answer is in.
        let deadline = Task<Void, Never> {
            // wakeup-allow: one-shot answer deadline; cancelled when the work answers first
            try? await Task<Never, Never>.sleep(for: wait)
            continuation.yield(nil)
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        for await answer in answers { return answer }
        return nil
    }
}
