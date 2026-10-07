import os

/// Settles one connect exactly once: the state handler, the deadline and
/// cancellation race; later calls are no-ops.
final class ConnectOutcome: Sendable {
    private let state = OSAllocatedUnfairLock<(CheckedContinuation<Result<Void, MobileLoopbackConnectError>, Never>?,
                                                Result<Void, MobileLoopbackConnectError>?)>(initialState: (nil, nil))

    func install(_ continuation: CheckedContinuation<Result<Void, MobileLoopbackConnectError>, Never>) {
        let settled: Result<Void, MobileLoopbackConnectError>? = state.withLock { value in
            if let result = value.1 { return result }
            value.0 = continuation
            return nil
        }
        if let settled { continuation.resume(returning: settled) }
    }

    func finish(_ result: Result<Void, MobileLoopbackConnectError>) {
        let continuation: CheckedContinuation<Result<Void, MobileLoopbackConnectError>, Never>? = state.withLock { value in
            guard value.1 == nil else { return nil }
            value.1 = result
            let waiting = value.0
            value.0 = nil
            return waiting
        }
        continuation?.resume(returning: result)
    }
}
