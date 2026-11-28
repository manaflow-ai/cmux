import Foundation
import CmuxNextCompat

/// Holds events that arrive before the handshake finishes, then releases
/// them after the `.connected` marker. Runs on the reader thread.
final class EventGate: Sendable {
    private struct State {
        var open = false
        var held: [DaemonEventEnvelope] = []
    }

    private let state = Mutex(State())

    func deliver(_ event: DaemonEventEnvelope, _ yield: (DaemonEventEnvelope) -> Void) {
        let passthrough = state.withLock { state -> Bool in
            if state.open { return true }
            state.held.append(event)
            return false
        }
        if passthrough { yield(event) }
    }

    /// Yields `first`, then the held events, then opens. Holding the lock
    /// while yielding keeps a concurrent `deliver` from jumping the queue.
    func open(first: DaemonEventEnvelope, _ yield: (DaemonEventEnvelope) -> Void) {
        state.withLock { state in
            yield(first)
            for event in state.held { yield(event) }
            state.held.removeAll()
            state.open = true
        }
    }
}

/// One subscribe-stream event with its position in the connection's total
/// order. Sequences grow across reconnects: the transport serial sits in the
/// high bits, the per-transport event index in the low 40.
public struct DaemonEventEnvelope: Sendable, Hashable {
    public let sequence: UInt64
    public let event: DaemonEvent

    public init(sequence: UInt64, event: DaemonEvent) {
        self.sequence = sequence
        self.event = event
    }

    static let lastIndex: UInt64 = (1 << 40) - 1

    static func sequence(serial: UInt64, index: UInt64) -> UInt64 {
        (serial << 40) | min(index, lastIndex)
    }
}
