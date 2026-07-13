import os

/// Bridges structured task cancellation into the synchronous process callback lifecycle.
final class CommandCancellationRegistration: Sendable {
    private struct State {
        var isCancelled = false
        var isFinished = false
        var handler: (@Sendable () -> Void)?
    }

    // Cancellation is a one-shot synchronous callback race; an actor would add
    // suspension and reentrancy to Process/continuation callbacks that must claim inline.
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ handler: @escaping @Sendable () -> Void) {
        let handlerToRun = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.isFinished else { return nil }
            guard !state.isCancelled else { return handler }
            state.handler = handler
            return nil
        }
        handlerToRun?()
    }

    func cancel() {
        let handler = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.isCancelled else { return nil }
            state.isCancelled = true
            defer { state.handler = nil }
            return state.handler
        }
        handler?()
    }

    func finish() {
        state.withLock {
            $0.isFinished = true
            $0.handler = nil
        }
    }
}
