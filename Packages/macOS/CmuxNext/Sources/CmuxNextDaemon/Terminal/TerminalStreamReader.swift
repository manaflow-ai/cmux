import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One terminal view's client stream on a shared daemon connection
/// (`attach-streams-v1`): turns the stream's frames and events into the view's
/// ``TerminalChannelEvent``s on the connection's reader thread.
///
/// It never waits: the reader serves every view and the control plane. A view
/// that falls behind, and any break in the stream's offsets, resyncs by snapshot
/// (drop the pending output, `snapshot-request gap`, apply nothing until the
/// next READY), so a slow view never stalls another (D5, design section 3.4).
final class TerminalStreamReader: Sendable {
    private struct State {
        /// The stream id, set right after the transport minted it (before any
        /// request names it, so before any message).
        var stream: UInt16 = 0
        var sequencer = TerminalSnapshotSequencer()
        /// Where the next OUTPUT frame must start; nil on a replay stream,
        /// whose frames carry no offsets.
        var expectedOffset: UInt64?
        /// A gap or an overflow was found: output is dropped until a READY.
        var resyncing = false
        /// The stream is a snapshot stream (it can resync by snapshot).
        var snapshots = false
        /// The terminal's output ring, once its RING frame mapped it.
        var ring: TerminalOutputRingMapping?
        /// The last READY's offset: a lap of bytes before it is moot (that
        /// READY replaced them).
        var readyOffset: UInt64 = 0
        /// Ring span bytes handed to the view and not released yet (queued
        /// or being parsed); at most the mapping's `outstandingBudget`.
        var outstandingRingBytes: UInt64 = 0
    }

    private let transport: LineTransport
    private let queue: TerminalEventQueue
    private let control: TerminalAttachment.ControlBox
    private let resolvedSurface: TerminalAttachment.SurfaceBox
    // A lock, not an actor (written exception to the CLAUDE.md actor rule): every
    // caller is a synchronous callback that cannot await. The transport's reader
    // thread delivers the stream's messages in wire order, and the order IS the
    // state machine: an actor would turn each message into a Task hop and let a
    // later message run first. Ring span deallocators run on the output lane's
    // queue when Ghostty releases a span. Each critical section is a few field
    // updates with no I/O and no call out (spans are cut and events queued after
    // the lock is released), so neither caller ever waits on the other for long.
    private let state = Mutex(State())

    init(transport: LineTransport, queue: TerminalEventQueue, control: TerminalAttachment.ControlBox,
         resolvedSurface: TerminalAttachment.SurfaceBox) {
        self.transport = transport
        self.queue = queue
        self.control = control
        self.resolvedSurface = resolvedSurface
    }

    /// The stream's mapped ring (tests: the zero-copy check).
    var ringMapping: TerminalOutputRingMapping? { state.withLock { $0.ring } }

    var stream: UInt16 {
        get { state.withLock { $0.stream } }
        set { state.withLock { $0.stream = newValue } }
    }

    /// Frames of this stream that named a kind a view does not take (a
    /// contract drift); diagnostics and tests.
    let unexpectedFrames = Atomic<Int>(0)

    func receive(_ message: LineTransport.StreamMessage) {
        switch message {
        case .closed(let reason):
            queue.finish(.closed(Self.closeReason(reason)))
        case .event(let name, let line):
            event(name: name, line: line)
        case .frame(let header, let payload):
            frame(header, payload)
        case .ring(_, _, let descriptor):
            mapRing(descriptor)
        }
    }

    /// Maps the stream's ring. A ring that does not map is a daemon fault the
    /// stream cannot read past (its output then only travels in the ring):
    /// the stream ends and the view reattaches.
    private func mapRing(_ descriptor: Int32) {
        do {
            let ring = try TerminalOutputRingMapping(descriptor: descriptor)
            state.withLock { $0.ring = ring }
        } catch {
            TerminalAttachment.decodeLogger.error("output ring not mapped: \(String(describing: error), privacy: .public)")
            queue.finish(.closed(.connectionLost("the terminal's output ring could not be mapped")))
            send(CancelStreamRequest())
        }
    }

    /// RING_ADVANCE: the ring holds the stream's bytes up to `end`. They reach
    /// the view as spans of the mapping, never copied. A read that is lost or
    /// being overwritten, or one that would leave the view holding more than
    /// the ring's outstanding budget, is a gap instead (design 4.4).
    private func ringAdvanced(to end: UInt64) {
        enum Next { case drop, gap, cut(TerminalOutputRingMapping, UInt64) }
        let next: Next = state.withLock { stream in
            guard !stream.resyncing, let ring = stream.ring, let start = stream.expectedOffset, end > start else {
                return .drop
            }
            guard stream.outstandingRingBytes + (end - start) <= ring.outstandingBudget else {
                stream.resyncing = true
                return .gap
            }
            stream.expectedOffset = end
            stream.outstandingRingBytes += end - start
            return .cut(ring, start)
        }
        switch next {
        case .drop:
            return
        case .gap:
            requestResync()
        case .cut(let ring, let start):
            // Outside the lock: an inline span releases inside `spans`.
            let spans = ring.spans(from: start, to: end) { [weak self] start, count, lapped in
                self?.released(start: start, count: count, lapped: lapped)
            }
            guard let spans else {
                state.withLock { stream in
                    stream.outstandingRingBytes -= end - start
                    stream.resyncing = true
                }
                requestResync()
                return
            }
            for span in spans { admit(DecodedAttachLine(event: .output(span, colors: nil))) }
        }
    }

    /// A span was parsed and released. One the writer lapped during the parse
    /// resyncs the view, unless a READY at or after it already replaced those
    /// bytes.
    private func released(start: UInt64, count: Int, lapped: Bool) {
        let resync = state.withLock { stream -> Bool in
            stream.outstandingRingBytes -= UInt64(truncatingIfNeeded: count)
            guard lapped, start >= stream.readyOffset, !stream.resyncing else { return false }
            stream.resyncing = true
            return true
        }
        if resync { requestResync() }
    }

    private static func closeReason(_ reason: TransportCloseReason) -> TerminalChannelCloseReason {
        switch reason {
        case .closedByClient: .connectionLost("closed")
        case .daemonShutdown: .connectionLost("daemon shut down")
        case .lost(let detail): .connectionLost(detail)
        }
    }

    // MARK: Events

    private struct StreamEnd: Decodable {
        var reason: String?
    }

    private func event(name: String, line: Data) {
        if name == "stream-end" {
            let reason = (try? WireCoding.decoder().decode(StreamEnd.self, from: line))?.reason
            let canceled = control.value.withLock { $0.canceled }
            let closed: TerminalChannelCloseReason = reason == "overflow" ? .overflow
                : canceled ? .detachedByClient : .surfaceGone
            queue.finish(.closed(closed))
            return
        }
        let surface = resolve(name: name, line: line)
        guard let decoded = TerminalAttachment.decodeAttachLine(name: name, line: line, surface: surface) else { return }
        if case .snapshot(let frame) = decoded.event, frame.phase == .ready {
            restarted(at: frame.offset)
        }
        admit(decoded)
    }

    /// The view's surface; an `unplaced` view takes the one its first event names.
    private func resolve(name: String, line: Data) -> SurfaceID {
        let surface = resolvedSurface.value.withLock { $0 }
        guard surface == TerminalAttachment.unresolvedSurface,
              let named = TerminalAttachment.initialSurface(name: name, line: line) else { return surface }
        resolvedSurface.value.withLock { $0 = named }
        return named
    }

    // MARK: Frames

    private struct EventName: Decodable {
        var event: String
    }

    private func frame(_ header: AttachFrameHeader, _ payload: Data) {
        switch header.kind {
        case .output:
            guard admitsOutput(at: header.offset, count: payload.count) else { return }
            admit(DecodedAttachLine(event: .output(payload, colors: nil)))
        case .snapshot, .snapshotMore:
            guard let parts = AttachFrameMeta(payload),
                  let snapshot = try? WireCoding.decoder().decode(TerminalAttachment.Snapshot.self, from: parts.meta)
            else { return undecodable(header) }
            let surface = resolve(name: "snapshot", line: parts.meta)
            guard snapshot.surface == nil || snapshot.surface == surface,
                  let decoded = TerminalAttachment.snapshotLine(snapshot, data: parts.data) else { return }
            if header.kind == .snapshot { restarted(at: snapshot.offset) }
            admit(decoded)
        case .replay:
            guard let parts = AttachFrameMeta(payload),
                  let name = try? WireCoding.decoder().decode(EventName.self, from: parts.meta).event,
                  var state = try? WireCoding.decoder().decode(TerminalAttachment.VTState.self, from: parts.meta)
            else { return undecodable(header) }
            let surface = resolve(name: name, line: parts.meta)
            guard state.surface == nil || state.surface == surface else { return }
            let pendingLength = min(state.pendingLength ?? 0, parts.data.count)
            state.replay = parts.data.prefix(parts.data.count - pendingLength)
            state.pending = parts.data.suffix(pendingLength)
            self.state.withLock { stream in
                // A replay stream has no offsets to check.
                stream.expectedOffset = nil
                stream.resyncing = false
                stream.snapshots = false
            }
            switch name {
            case "vt-state": admit(DecodedAttachLine(event: .replay(state.terminalReplay)))
            case "resized": admit(DecodedAttachLine(event: .resized(state.terminalReplay)))
            default: undecodable(header)
            }
        case .ringAdvance:
            ringAdvanced(to: header.offset)
        case .event, .grid, .ring:
            // EVENT and RING frames arrive as their own messages (LineTransport);
            // GRID needs a capability this view does not advertise yet.
            undecodable(header)
        }
    }

    private func undecodable(_ header: AttachFrameHeader) {
        let count = unexpectedFrames.add(1, ordering: .relaxed).newValue
        TerminalAttachment.decodeLogger.error("attach frame kind \(header.kind.rawValue) not decoded (\(count) so far)")
    }

    /// A READY at `offset`: output continues from there; a resync is over.
    private func restarted(at offset: UInt64) {
        state.withLock { stream in
            stream.expectedOffset = offset
            stream.readyOffset = offset
            stream.resyncing = false
            stream.snapshots = true
        }
    }

    /// Whether OUTPUT `[offset, offset + count)` continues the stream. Bytes
    /// before the expected offset belong to a screen a READY replaced
    /// (dropped); bytes after it mean bytes went missing (a gap: resync).
    private func admitsOutput(at offset: UInt64, count: Int) -> Bool {
        let verdict: (admit: Bool, gap: Bool) = state.withLock { stream in
            if stream.resyncing { return (false, false) }
            guard let expected = stream.expectedOffset else { return (true, false) }
            if offset + UInt64(truncatingIfNeeded: count) <= expected { return (false, false) }
            guard offset == expected else {
                stream.resyncing = true
                return (false, true)
            }
            stream.expectedOffset = expected + UInt64(truncatingIfNeeded: count)
            return (true, false)
        }
        if verdict.gap { requestResync() }
        return verdict.admit
    }

    // MARK: Delivery

    private func admit(_ decoded: DecodedAttachLine) {
        let event: TerminalChannelEvent? = state.withLock { stream in
            if stream.resyncing, case .output = decoded.event { return nil }
            return stream.sequencer.admit(decoded)
        }
        guard let event else { return }
        if case .sizeState(let sizeState, let selfParticipant) = event {
            TerminalAttachment.admitSizeState(sizeState, selfParticipant: selfParticipant, control: control, queue: queue)
            return
        }
        if case .closed = event {
            queue.finish(event)
            return
        }
        if case .output = event { TypingLatencyProbe.shared.mark(.outputDecoded) }
        guard queue.push(event) == .overflowed else { return }
        overflowed()
    }

    /// The view fell `highWater` behind and lost its queued output. A snapshot
    /// stream resyncs; a replay stream cannot, so it ends and the view
    /// reattaches (as a dedicated connection's overflow does).
    private func overflowed() {
        let snapshots = state.withLock { stream -> Bool in
            if stream.snapshots { stream.resyncing = true }
            return stream.snapshots
        }
        if snapshots {
            requestResync()
            return
        }
        queue.finish(.closed(.overflow))
        send(CancelStreamRequest())
    }

    private func requestResync() {
        send(SnapshotRequestRequest(surface: resolvedSurface.value.withLock { $0 }, reason: .gap))
    }

    private func send<R: DaemonRequest>(_ request: R) {
        let stream = stream
        do {
            try transport.sendNoReply(cmd: R.command, onError: { error in
                TerminalAttachment.decodeLogger.error("\(R.command, privacy: .public) failed: \(error.description, privacy: .public)")
            }) { id in
                try WireCoding.encodeRequest(request, id: id, stream: stream)
            }
        } catch {
            TerminalAttachment.decodeLogger.debug("\(R.command, privacy: .public) dropped after close")
        }
    }
}
