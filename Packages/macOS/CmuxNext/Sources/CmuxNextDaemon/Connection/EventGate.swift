public import CmuxNextWakeups
public import Foundation
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
    /// The emitting connection instance, absent for legacy or manually constructed envelopes.
    public let sourceID: UUID?
    /// The emitting control connection's serial, scoped to its ``DaemonConnection`` instance.
    ///
    /// This is source metadata, not a route or permission grant. Compare it
    /// only with a serial captured from the same connection instance.
    public var connectionSerial: UInt64 { sequence >> 40 }
    public let sequence: UInt64
    public let event: DaemonEvent
    /// Who caused the event (p06-scheduler-031, ``DaemonEvent/cause(wire:recorded:)``): person for the
    /// echo of the app's own person-scope mutation, else the daemon's envelope `cause`; program for
    /// synthetic events and when the daemon sent none. The drain applies the event with it as the
    /// current cause (``ObservationCauses``). Scheduling only: authorization never reads it.
    public let cause: ObservationCause

    /// Preserves an event's original ordering and source identity.
    /// - Parameters:
    ///   - sequence: The connection serial and event index encoded by the transport.
    ///   - event: The decoded native event.
    ///   - sourceID: The emitting connection instance; nil for legacy or synthetic events.
    ///   - cause: Who caused it; ``ObservationCause/program`` when the daemon names no cause.
    public init(sequence: UInt64, event: DaemonEvent, sourceID: UUID? = nil, cause: ObservationCause = .program) {
        self.sourceID = sourceID
        self.sequence = sequence
        self.event = event
        self.cause = cause
    }

    /// This envelope with its cause raised to `other` when that is higher: what an inbox merge or a
    /// collapse keeps for the events it stands for.
    public func raisingCause(to other: ObservationCause) -> DaemonEventEnvelope {
        guard other > cause else { return self }
        return DaemonEventEnvelope(sequence: sequence, event: event, sourceID: sourceID, cause: other)
    }

    static let lastIndex: UInt64 = (1 << 40) - 1

    static func sequence(serial: UInt64, index: UInt64) -> UInt64 {
        (serial << 40) | min(index, lastIndex)
    }
}
