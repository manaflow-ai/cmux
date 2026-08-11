import CmuxTerminal

/// Thread-safe bridge from nonisolated surface teardown to the main actor.
final class TerminalBackendPresentationLease: TerminalExternalPresentationLease, Sendable {
    private let action: @Sendable () -> Void

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    nonisolated func detach() {
        // The main-actor runtime owns idempotence. Repeated schedules stop at
        // its `detached` state and cannot repeat a daemon-side mutation.
        action()
    }

    deinit {
        detach()
    }
}
