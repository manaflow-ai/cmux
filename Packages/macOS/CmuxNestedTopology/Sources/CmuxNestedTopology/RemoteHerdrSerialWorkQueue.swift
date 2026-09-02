import Foundation

/// Serializes snapshot apply and pane send so later work remains applied.
///
/// Isolation: actor. Each ``Stream`` is an independent FIFO; later enqueues
/// wait for earlier work on the same stream before they run.
public actor RemoteHerdrSerialWorkQueue {
    /// Independent FIFO. Snapshot apply and per-pane send do not share a tail.
    public enum Stream: Hashable, Sendable {
        /// Session topology apply / restore snapshot.
        case snapshot
        /// Ordered `pane.send` for one Herdr pane id.
        case send(paneID: String)
    }

    private var tails: [Stream: (id: UUID, task: Task<Void, Never>)] = [:]

    /// Runs `work` after any previous work on `stream`.
    ///
    /// - Parameter stream: FIFO that must stay ordered.
    /// - Parameter work: Unit of apply or send.
    /// - Returns: The value produced by `work`.
    public func enqueue<T: Sendable>(
        _ stream: Stream,
        _ work: @Sendable @escaping () async -> T
    ) async -> T {
        let previous = tails[stream]?.task
        let id = UUID()
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        tails[stream] = (id, Task { _ = await task.value })
        let result = await task.value
        if tails[stream]?.id == id {
            tails[stream] = nil
        }
        return result
    }

    /// Number of streams still retaining a tail. Idle streams are dropped.
    func trackedStreamCount() -> Int { tails.count }
}
