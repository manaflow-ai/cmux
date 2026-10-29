import os

/// Exclusive access to one ordered pasteboard read in cmux's process-wide
/// clipboard lane.
///
/// SAFETY: the unfair lock protects the complete lease state machine; no
/// mutable state is accessed outside it, and callbacks run after unlocking.
public final class TerminalPasteboardReadLease: @unchecked Sendable {
    private enum State {
        case waiting(CheckedContinuation<Bool, Never>?)
        case ready
        case finished
    }

    let id: UInt64
    private let state = OSAllocatedUnfairLock<State>(
        initialState: .waiting(nil)
    )
    private let finishHandler: @Sendable () -> Void

    init(
        id: UInt64,
        finishHandler: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.finishHandler = finishHandler
    }

    /// Waits until every earlier cmux-owned read or write has finished.
    public func waitUntilReady() async -> Bool {
        if Task.isCancelled {
            finish()
            return false
        }
        let becameReady = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediateResult = state.withLock { state -> Bool? in
                    switch state {
                    case .waiting(nil):
                        state = .waiting(continuation)
                        return nil
                    case .waiting:
                        preconditionFailure("Pasteboard lease awaited twice")
                    case .ready:
                        return true
                    case .finished:
                        return false
                    }
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            finish()
        }
        guard becameReady else { return false }
        return state.withLock { state in
            if case .ready = state { return true }
            return false
        }
    }

    /// Releases the lane after pasteboard-backed preparation no longer reads.
    public func finish() {
        let outcome = state.withLock {
            state -> (shouldFinish: Bool, continuation: CheckedContinuation<Bool, Never>?) in
            switch state {
            case .waiting(let continuation):
                state = .finished
                return (true, continuation)
            case .ready:
                state = .finished
                return (true, nil)
            case .finished:
                return (false, nil)
            }
        }
        guard outcome.shouldFinish else { return }
        outcome.continuation?.resume(returning: false)
        finishHandler()
    }

    var isReady: Bool {
        state.withLock { state in
            if case .ready = state { return true }
            return false
        }
    }

    func signalReady() {
        let continuation = state.withLock {
            state -> CheckedContinuation<Bool, Never>? in
            switch state {
            case .waiting(let continuation):
                state = .ready
                return continuation
            case .ready, .finished:
                return nil
            }
        }
        continuation?.resume(returning: true)
    }

    deinit {
        finish()
    }
}
