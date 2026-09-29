import Foundation
import Synchronization
import os

/// Holds events that arrive before the handshake finishes, then releases
/// them after the `.connected` marker. Runs on the reader thread.
final class EventGate: Sendable {
    private struct State {
        var open = false
        var held: [DaemonEvent] = []
    }

    private let state = Mutex(State())

    func deliver(_ event: DaemonEvent, _ yield: (DaemonEvent) -> Void) {
        let passthrough = state.withLock { state -> Bool in
            if state.open { return true }
            state.held.append(event)
            return false
        }
        if passthrough { yield(event) }
    }

    /// Yields `first`, then the held events, then opens. Holding the lock
    /// while yielding keeps a concurrent `deliver` from jumping the queue.
    func open(first: DaemonEvent, _ yield: (DaemonEvent) -> Void) {
        state.withLock { state in
            yield(first)
            for event in state.held { yield(event) }
            state.held.removeAll()
            state.open = true
        }
    }
}
