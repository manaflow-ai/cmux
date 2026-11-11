public import CmuxNextHistory
public import Foundation

extension HistoryWriteQueue {
    /// Queues one location trail step (`record`, the daemon's `history.trail.record` with the write's key) behind every
    /// earlier visit, clear and remove: a step taken before a Clear History reaches the daemon before that clear, so the
    /// clear removes it instead of the step bringing the place back (cmux#38186 review). Each attempt and its reply or
    /// failure goes to `log`; a failure is thrown on, so a link drop or an unknown outcome goes again with the same key and
    /// a refusal ends it. A step is droppable for room like a visit, and moves no queued read.
    public func enqueueTrailStep(_ location: HistoryLocation, at time: Date, steps: HistoryStepScope, jump: Bool, log: HistoryTrailLog,
                                 _ record: @escaping @Sendable (Client, _ key: String) async throws -> (id: String?, recorded: Bool?)) {
        let atMs = HistoryTrailStepID(location.key, time).ms
        enqueue(visit: true) { client, key in
            log.reported(location, atMs: atMs, steps: steps.rawValue, jump: jump)
            do {
                let reply = try await record(client, key)
                log.replied(location, id: reply.id, recorded: reply.recorded)
            } catch {
                log.failed(location, error)
                throw error
            }
        }
    }
}
