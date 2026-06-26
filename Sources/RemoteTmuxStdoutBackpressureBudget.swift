import os

private struct RemoteTmuxStdoutBackpressureState: Sendable {
    var pendingBytes = 0
    var closed = false
}

// Safe to share across FileHandle callbacks and main-actor ingestion: every
// mutable field is behind this tiny lock. An actor would require an async hop
// after stdout has already been read from the pipe, too late to apply backpressure.
final class RemoteTmuxStdoutBackpressureBudget: @unchecked Sendable {
    private let maxPendingBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: RemoteTmuxStdoutBackpressureState())

    init(maxPendingBytes: Int) {
        self.maxPendingBytes = maxPendingBytes
    }

    func reserve(byteCount: Int) -> Bool {
        guard byteCount > 0 else { return true }
        return state.withLock { state in
            guard !state.closed,
                  byteCount <= maxPendingBytes - state.pendingBytes else {
                return false
            }
            state.pendingBytes += byteCount
            return true
        }
    }

    func release(byteCount: Int) {
        guard byteCount > 0 else { return }
        state.withLock { state in
            state.pendingBytes = max(0, state.pendingBytes - byteCount)
        }
    }

    func close() {
        state.withLock { state in
            state.closed = true
            state.pendingBytes = 0
        }
    }
}
