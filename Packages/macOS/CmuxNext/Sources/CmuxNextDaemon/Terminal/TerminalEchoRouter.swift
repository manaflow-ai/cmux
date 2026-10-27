import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// The attach reader's side of one terminal stream: snapshot order (``TerminalSnapshotSequencer``),
/// then each admitted event either straight to the view's lane (live output while the
/// ``TerminalEchoRoute`` is open) or onto the ``TerminalEventQueue`` the driver consumes.
///
/// Live output therefore reaches the lane in one call on the reader thread: no AsyncStream, no task
/// and no cooperative pool thread between the socket and the parser. Back-pressure is the lane's
/// capacity, waited for on the reader thread (``TerminalEventQueue/waitForLane(_:)``), so a slow
/// parser stops the socket and the daemon's bounded mailbox ends a stalled view with `overflow`, as
/// the stream's own high water does.
///
/// Records and markers are queued under one lock, so a marker is always behind the record that
/// asked for it; the waits (the queue's high water, the lane's capacity) run outside it.
final class TerminalEchoRouter: Sendable {
    private struct State {
        var sequencer = TerminalSnapshotSequencer()
        var route = TerminalEchoRoute()
    }

    /// What the reader does with an event once it is out of the lock.
    private enum Next {
        case drop
        case sizeState(TerminalSizeState, participant: String?)
        case lane(TerminalEchoSink, Data, flow: UInt64?)
        case queued
    }

    private let state = Mutex(State())
    private let queue: TerminalEventQueue
    /// Where decoded echoes are marked (``TypingLatencyProbe/shared``, or a test's).
    private let probe: TypingLatencyProbe

    init(queue: TerminalEventQueue, probe: TypingLatencyProbe = .shared) {
        self.queue = queue
        self.probe = probe
    }

    /// Reader thread, in stream order: one decoded attach line. A size state goes to `sizeState`
    /// (the attachment orders generations under its own lock); it touches no surface, so it keeps
    /// no order with output.
    func receive(_ decoded: DecodedAttachLine, sizeState: (TerminalSizeState, String?) -> Void) {
        let next = state.withLock { state -> Next in
            guard let event = state.sequencer.admit(decoded) else { return .drop }
            switch event {
            case .sizeState(let size, let participant):
                return .sizeState(size, participant: participant)
            case .closed:
                state.route.close()
                queue.finish(event)
                return .queued
            case .output(let data, _):
                probe.outputDecoded(flow: decoded.flow)
                if state.route.isOpen, let sink = state.route.sink { return .lane(sink, data, flow: decoded.flow) }
                queue.pushWithoutWaiting(event)
                if let flow = decoded.flow { queue.pushWithoutWaiting(.inputEcho(flow: flow)) } // rides behind its chunk
            default:
                queue.pushWithoutWaiting(event)
            }
            if let marker = state.route.recordQueued() { queue.pushWithoutWaiting(.outputResume(self.marker(marker))) }
            return .queued
        }
        switch next {
        case .drop: break
        case .sizeState(let size, let participant): sizeState(size, participant)
        case .lane(let sink, let data, let flow): queue.waitForLane { wake in sink.enqueueEcho(data, flow: flow, wake: wake) }
        case .queued: queue.waitWhileFull()
        }
    }

    /// Any thread: the view's lane for live output (nil: none; output stays on the stream).
    func setSink(_ sink: TerminalEchoSink?) {
        state.withLock { state in
            if let marker = state.route.install(sink) { queue.pushWithoutWaiting(.outputResume(self.marker(marker))) }
        }
    }

    /// The link detached: output stays on the stream, and a reader waiting for the lane goes on.
    func close() {
        state.withLock { $0.route.close() }
        queue.releaseLane(closing: true)
    }

    /// Whether the next output chunk goes straight to the lane (tests, diagnostics).
    var routesToLane: Bool { state.withLock { $0.route.isOpen } }

    private func marker(_ sequence: UInt64) -> TerminalOutputMarker {
        TerminalOutputMarker(sequence: sequence) { [weak self] sequence in self?.acknowledge(sequence) }
    }

    private func acknowledge(_ sequence: UInt64) {
        state.withLock { state in
            if let marker = state.route.acknowledge(sequence) { queue.pushWithoutWaiting(.outputResume(self.marker(marker))) }
        }
    }
}
