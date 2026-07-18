import CmuxTerminal
import os

/// Thread-safe one-shot bridge from nonisolated surface teardown to the main actor.
final class TerminalBackendPresentationLease: TerminalExternalPresentationLease, @unchecked Sendable {
    private struct State {
        var action: (@Sendable () -> Void)?
    }

    // The protocol requires synchronous, nonisolated idempotence. This lock
    // protects only the compare-and-clear of one closure; runtime state remains actor-owned.
    private let state: OSAllocatedUnfairLock<State>

    init(action: @escaping @Sendable () -> Void) {
        state = OSAllocatedUnfairLock(initialState: State(action: action))
    }

    nonisolated func detach() {
        let action = state.withLock { state in
            defer { state.action = nil }
            return state.action
        }
        action?()
    }

    deinit {
        detach()
    }
}
