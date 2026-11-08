internal import os

/// Synchronous state for non-async telemetry entrypoints and revocation hooks.
final class AnalyticsCriticalState<State: Sendable>: Sendable {
    // lint:allow lock - synchronous consent and cancellation entrypoints cannot await an actor without reopening revoke races.
    private let state: OSAllocatedUnfairLock<State>

    init(initialValue: State) {
        state = .init(initialState: initialValue)
    }

    func withCriticalRegion<Result: Sendable>(
        _ body: @Sendable (inout State) throws -> sending Result
    ) rethrows -> sending Result {
        try state.withLock(body)
    }
}
