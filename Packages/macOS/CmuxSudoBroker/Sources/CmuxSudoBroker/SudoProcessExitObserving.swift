import Foundation

/// Supplies an asynchronous signal when a generation-qualified process exits.
protocol SudoProcessExitObserving: Sendable {
    func events(for identity: SudoProcessIdentity) -> AsyncStream<Void>
}
