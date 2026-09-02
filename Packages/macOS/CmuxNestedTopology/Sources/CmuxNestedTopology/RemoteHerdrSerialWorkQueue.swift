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

    private var tails: [Stream: Task<Void, Never>] = [:]

    /// Runs `work` after any previous work on `stream`.
    ///
    /// - Parameter stream: FIFO that must stay ordered.
    /// - Parameter work: Unit of apply or send.
    /// - Returns: The value produced by `work`.
    public func enqueue<T: Sendable>(
        _ stream: Stream,
        _ work: @Sendable @escaping () async -> T
    ) async -> T {
        let previous = tails[stream]
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        tails[stream] = Task { _ = await task.value }
        return await task.value
    }
}
