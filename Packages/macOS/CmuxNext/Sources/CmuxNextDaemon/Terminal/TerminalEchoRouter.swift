import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// The attach connection's side of one terminal stream: snapshot order (``TerminalSnapshotSequencer``),
/// then each admitted event either straight to the view's lane (live output while the
/// ``TerminalEchoRoute`` is open), held behind the marker in flight (live output while only output
/// came after it), or onto the ``TerminalEventQueue`` the driver consumes.
///
/// Live output therefore reaches the lane in one call on the connection's decode lane, inline on its reader
/// while that lane is idle: no AsyncStream, no task and no cooperative pool thread between the
/// socket and the parser. After a record the route opens
/// again one round trip later even while output keeps coming: the output that came meanwhile waits
/// here and the marker's acknowledgement hands it to the lane. Back-pressure is the lane's capacity,
/// and the hold limit while output waits for a marker, both waited for on the reader thread after the line
/// (``TerminalEventQueue/enqueueOnLane(_:)``, ``TerminalEventQueue/waitWhileFull()``), so a slow parser
/// stops the socket and the daemon's bounded mailbox ends a stalled view with `overflow`, as the
/// stream's own high water does.
///
/// Records, markers and held output are queued under one lock, so a marker is always behind the
/// record that asked for it and held output reaches the lane before any later chunk; the hold limit
/// is set and released under it too. The waits (the queue's high water, the lane's capacity, the hold
/// limit) run outside it.
final class TerminalEchoRouter: Sendable {
    /// What the reader does with an event once it is out of the lock.
    private enum Next {
        case drop
        case sizeState(TerminalSizeState, participant: String?)
        case lane(TerminalEchoSink, Data, flow: UInt64?)
        case queued
    }

    private struct State {
        var sequencer = TerminalSnapshotSequencer()
        var route: TerminalEchoRoute
    }

    private let state: Mutex<State>
    private let queue: TerminalEventQueue
    /// Where decoded echoes are marked (``TypingLatencyProbe/shared``, or a test's).
    private let probe: TypingLatencyProbe

    /// - Parameter holdLimit: Bytes of output held behind a marker above which the reader waits for the
    ///   marker's acknowledgement: the view's lane capacity (`TerminalOutputLane.highWater`).
    init(queue: TerminalEventQueue, holdLimit: Int = 2 << 20, probe: TypingLatencyProbe = .shared) {
        self.queue = queue
        self.probe = probe
        state = Mutex(State(route: TerminalEchoRoute(holdLimit: holdLimit)))
    }

    /// In stream order: one decoded attach line, then the reader's wait (``TerminalEventQueue/waitWhileFull()``).
    /// The attach connection runs the two halves on two threads (``admit(_:sizeState:)`` on its decode lane, the
    /// wait on its reader after the line); this runs both on the caller's.
    func receive(_ decoded: DecodedAttachLine, sizeState: (TerminalSizeState, String?) -> Void) {
        admit(decoded, sizeState: sizeState)
        queue.waitWhileFull()
    }

    /// The attach connection's decode lane (or its reader inline), in stream order: one decoded attach line. A
    /// size state goes to `sizeState` (the attachment orders generations under its own lock); it touches no
    /// surface, so it keeps no order with output. Never waits: what holds the reader (the lane's capacity, the
    /// hold limit, the queue's high water) the reader waits for after the line.
    func admit(_ decoded: DecodedAttachLine, sizeState: (TerminalSizeState, String?) -> Void) {
        let next = state.withLock { state -> Next in
            guard let event = state.sequencer.admit(decoded) else { return .drop }
            switch event {
            case .sizeState(let size, let participant):
                return .sizeState(size, participant: participant)
            case .closed:
                queueHeld(state.route.close())
                queue.finish(event)
                return .queued
            case .output(let data, let colors):
                probe.outputDecoded(flow: decoded.flow)
                switch state.route.route(data, colors: colors, flow: decoded.flow) {
                case .lane(let sink): return .lane(sink, data, flow: decoded.flow)
                case .held(let full):
                    if full { queue.holdForMarker() }
                    return .queued
                case .stream: queueOutput(TerminalEchoRoute.Held(data: data, colors: colors, flow: decoded.flow))
                }
            default:
                queueHeld(state.route.takeHeld())
                queue.pushWithoutWaiting(event)
            }
            if let marker = state.route.recordQueued() { queue.pushWithoutWaiting(.outputResume(self.marker(marker))) }
            return .queued
        }
        switch next {
        case .drop: break
        case .sizeState(let size, let participant): sizeState(size, participant)
        case .lane(let sink, let data, let flow): queue.enqueueOnLane { wake in sink.enqueueEcho(data, flow: flow, wake: wake) }
        case .queued: break
        }
    }

    /// Any thread: the view's lane for live output (nil: none; output stays on the stream).
    func setSink(_ sink: TerminalEchoSink?) {
        state.withLock { state in
            let (held, marker) = state.route.install(sink)
            queueHeld(held)
            if let marker { queue.pushWithoutWaiting(.outputResume(self.marker(marker))) }
        }
    }

    /// The link detached: output stays on the stream, and a reader waiting for the lane goes on.
    func close() {
        state.withLock { queueHeld($0.route.close()) }
        queue.releaseLane(closing: true)
    }

    /// The connection's decode lane: the connection closed. Ends the stream after any output still held.
    func finish(_ last: TerminalChannelEvent) {
        state.withLock { state in
            queueHeld(state.route.close())
            queue.finish(last)
        }
    }

    /// Whether the next output chunk goes straight to the lane (tests, diagnostics).
    var routesToLane: Bool { state.withLock { $0.route.isOpen } }

    private func marker(_ sequence: UInt64) -> TerminalOutputMarker {
        TerminalOutputMarker(sequence: sequence) { [weak self] sequence in self?.acknowledge(sequence) }
    }

    /// The consumer applied everything before marker `sequence`: the output held behind it goes to the
    /// lane, still under the lock so no later chunk overtakes it, and the reader waiting on it reads on.
    private func acknowledge(_ sequence: UInt64) {
        state.withLock { state in
            switch state.route.acknowledge(sequence) {
            case .nothing: break
            case .marker(let next): queue.pushWithoutWaiting(.outputResume(self.marker(next)))
            case .open(let sink, let held):
                // The reader's next chunk goes by the open route and waits on the lane if it is still full.
                for chunk in held { _ = sink.enqueueEcho(chunk.data, flow: chunk.flow, wake: {}) }
                queue.releaseMarkerHold()
            }
        }
    }

    /// Under the lock: output held behind a marker goes onto the stream, in order, ahead of the record queued
    /// next; nothing is held any more, so the hold limit no longer holds the reader.
    private func queueHeld(_ held: [TerminalEchoRoute.Held]) {
        guard !held.isEmpty else { return }
        held.forEach(queueOutput)
        queue.releaseMarkerHold()
    }

    /// Under the lock: one output chunk onto the stream, and the echo of its press right behind it.
    private func queueOutput(_ chunk: TerminalEchoRoute.Held) {
        queue.pushWithoutWaiting(.output(chunk.data, colors: chunk.colors))
        if let flow = chunk.flow { queue.pushWithoutWaiting(.inputEcho(flow: flow)) }
    }
}
