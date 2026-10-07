import os

/// Bytes and messages received, shared between a receive task and the
/// workload that reads progress.
final class ByteCounter: Sendable {
    // carve-out: one counter update per received message in a benchmark, never held across an await.
    private let state = OSAllocatedUnfairLock(initialState: (bytes: 0, messages: 0))

    func add(_ bytes: Int) {
        state.withLock {
            $0.bytes += bytes
            $0.messages += 1
        }
    }

    var bytes: Int { state.withLock { $0.bytes } }
    var messages: Int { state.withLock { $0.messages } }
}
