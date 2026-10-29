import Foundation

/// Turns one attach stream's frames into channel events, in stream order, on the reader thread
/// (attach-frames-v1; cmux-tui `server/attach_frames.rs` and `server/snapshot_frames.rs`).
///
/// Every attach frame's aux is an absolute PTY offset, and consecutive OUTPUT frames are contiguous, so the
/// decoder knows the offset of the next output byte and sees a gap the moment bytes are lost, as Chrome's
/// `viz::BeginFrameArgs` carry a sequence number for the same reason
/// (components/viz/common/frame_sinks/begin_frame_args.h):
///
/// - A REPLAY or a READY is the screen at its offset; output continues from there.
/// - OUTPUT at that offset passes as a slice of the read buffer (never copied). Bytes before it are already
///   on the screen (the READY's cut came after them): they are cut off by a narrower slice, or dropped.
/// - OUTPUT, a GRID or an event past that offset means bytes were lost. A snapshot stream asks for a
///   fresh READY (``TerminalFrameAdmission/resync(_:)``, once) and drops screen bytes until it comes; a
///   byte-replay stream cannot, so its view reattaches from a fresh replay, as on the daemon's `overflow`.
///   A repair that fails (the READY is refused, the stream breaks again before it, or the request fails)
///   also ends the stream with `overflow`, so a view never waits on a READY that will not come.
/// - SNAPSHOT/SNAPSHOT_MORE and REPLAY chunks are put back together by the lengths in their meta; an event
///   whose raw bytes all came in one frame is a slice too.
///
/// JSON lines of the same stream go through ``admit(line:named:decoder:)``, so one ``TerminalSnapshotSequencer``
/// orders both and one surface scopes both.
struct TerminalAttachFrameDecoder: Sendable {
    /// Largest snapshot or replay event put together from chunks (a JSON line replay is at most 32 MiB).
    static let maxBulkBytes = 64 << 20
    /// Bytes of the little-endian `meta_len` that opens GRID, SNAPSHOT and REPLAY payloads.
    static let metaLengthBytes = 4

    /// The stream's surface; ``TerminalAttachment/unresolvedSurface`` until a `vt-state` or READY, frame or
    /// line, names it.
    private(set) var surface: SurfaceID
    /// Offset of the next output byte; nil until the stream names one.
    private(set) var nextOffset: UInt64?
    /// Set by a gap on a snapshot stream: screen bytes are dropped until a READY restores the screen.
    private(set) var resyncing = false
    /// The stream restores from READY snapshots (a snapshot attach), so a gap is repaired in place.
    private var snapshots = false
    /// The contiguous OUTPUT frames just before this frame; the only output an `output` sidecar may follow.
    private var outputRun: OutputRun?
    private var sequencer = TerminalSnapshotSequencer()
    private var bulk: PendingBulk?

    init(surface: SurfaceID) {
        self.surface = surface
    }

    /// What `frame` gives the view. `decoder` is the connection's (it counts each meta decode).
    mutating func admit(_ frame: TerminalAttachFrame, decoder: WireDecoder) -> TerminalFrameAdmission {
        // A sidecar follows the last chunk of its OUTPUT at once; any other frame in between ends that chance.
        let precedingRun = outputRun
        outputRun = nil
        if let pending = bulk {
            // A stream's frames never interleave (one FIFO per stream), so another frame here is a broken stream.
            guard pending.continues(with: frame) else { return lost() }
            return appendBulk(frame.payload, decoder: decoder)
        }
        switch frame.kind {
        case .output:
            return output(TerminalOutputSpan(offset: frame.offset, bytes: frame.payload), after: precedingRun)
        case .grid:
            return grid(frame, decoder: decoder)
        case .event:
            return event(frame, after: precedingRun, decoder: decoder)
        case .snapshot, .replay:
            bulk = PendingBulk(kind: frame.kind, offset: frame.offset)
            return appendBulk(frame.payload, decoder: decoder)
        case .snapshotMore:
            return lost()  // a continuation of no SNAPSHOT
        }
    }

    /// A JSON line `name` of the same stream: an event the daemon sent as a line, such as a `vt-state` or
    /// READY too large for a frame (cmux-tui `snapshot_frames.rs`, `BulkFrameError`). It does what its frame
    /// does: an unresolved stream takes the surface it names, a READY sets the offset output continues from,
    /// and a `vt-state` (which names no offset) lets the next OUTPUT name it. A `snapshot` line it cannot use
    /// ends a resync, as a refused READY frame does.
    mutating func admit(line: Data, named name: String, decoder: WireDecoder) -> TerminalFrameAdmission {
        outputRun = nil
        if surface == TerminalAttachment.unresolvedSurface,
           let named = TerminalAttachment.initialSurface(name: name, line: line, decoder: decoder) {
            surface = named
        }
        guard let decoded = TerminalAttachment.decodeAttachLine(name: name, line: line, surface: surface,
                                                                decoder: decoder)
        else { return name == "snapshot" ? refusedReady() : .nothing }
        switch decoded.event {
        case .replay:
            restored(at: nil, snapshot: false)
        case .snapshot(let frame) where frame.phase == .ready:
            restored(at: frame.offset, snapshot: true)
        case .output, .resized:
            guard !resyncing else { return .nothing }  // screen bytes of the screen being replaced
        default:
            break
        }
        guard let event = sequencer.admit(decoded) else { return .nothing }
        return .event(event, flow: decoded.flow)
    }

    /// The writer cuts one output into OUTPUT frames of at most BULK_FRAME_MAX, each with the offset of its
    /// first byte (cmux-ipc `lane_writer.rs` `chunk_frame`), so `run` is the output this chunk may continue.
    private mutating func output(_ span: TerminalOutputSpan, after run: OutputRun?) -> TerminalFrameAdmission {
        guard !resyncing else { return .nothing }
        var current = run.flatMap { $0.end == span.offset ? $0 : nil }
            ?? OutputRun(start: span.offset, end: span.offset)
        current.end = span.end
        guard let next = nextOffset else {
            nextOffset = span.end
            current.deliveredEnd = span.end
            outputRun = current
            return .output(span)
        }
        guard span.offset <= next else { return lost() }
        // Bytes before `next` are on the screen already; only the rest is new.
        guard span.end > next, let rest = span.dropping(before: next) else {
            outputRun = current
            return .nothing
        }
        nextOffset = rest.end
        current.deliveredEnd = rest.end
        outputRun = current
        return .output(rest)
    }

    /// `meta_len | meta | replay | pending`: the `resized` event without `replay` and `pending`.
    private mutating func grid(_ frame: TerminalAttachFrame, decoder: WireDecoder) -> TerminalFrameAdmission {
        guard !resyncing else { return .nothing }
        if let next = nextOffset {
            guard frame.offset <= next else { return lost() }
            // The screen that set `next` (a READY or REPLAY cut after this resize) already has it.
            guard frame.offset == next else { return .nothing }
        }
        let payload = frame.payload
        guard let metaLength = payload.littleEndianUInt32(at: 0).map({ Int(clamping: $0) }),
              let meta = payload.slice(from: Self.metaLengthBytes, length: metaLength),
              let state = try? decoder.decode(TerminalVTStateWire.self, from: meta.data)
        else {
            TerminalAttachment.noteUndecodable("grid frame")
            return lost()
        }
        let rawStart = Self.metaLengthBytes + metaLength
        let pendingLength = state.pendingLen ?? 0
        let replayLength = payload.count - rawStart - pendingLength
        guard let replay = payload.slice(from: rawStart, length: replayLength),
              let pending = payload.slice(from: rawStart + replayLength, length: pendingLength)
        else {
            TerminalAttachment.noteUndecodable("grid frame")
            return lost()
        }
        guard scoped(state.surface) else { return .nothing }
        if nextOffset == nil { nextOffset = frame.offset }
        return .event(.resized(state.terminalReplay(data: replay.data, pending: pending.data)), flow: nil)
    }

    private struct EventName: Decodable {
        var event: String
    }

    /// The `output` event without `data`, after its OUTPUT.
    private struct OutputSidecar: Decodable {
        var surface: SurfaceID?
        var colors: TerminalColors?
        var flow: UInt64?
    }

    /// An attach event's JSON line, or the sidecar of the OUTPUT before it.
    private mutating func event(_ frame: TerminalAttachFrame, after run: OutputRun?,
                                decoder: WireDecoder) -> TerminalFrameAdmission {
        let line = frame.payload.data
        guard let name = try? decoder.decode(EventName.self, from: line).event else {
            TerminalAttachment.noteUndecodable("event frame")
            return .nothing
        }
        if name == "output" {
            // The sidecar of output that was dropped (already on the screen, or lost) is dropped with it.
            guard run?.carries(sidecarAt: frame.offset) == true else { return .nothing }
            guard let sidecar = try? decoder.decode(OutputSidecar.self, from: line) else {
                TerminalAttachment.noteUndecodable("output sidecar")
                return .nothing
            }
            guard scoped(sidecar.surface) else { return .nothing }
            if let colors = sidecar.colors { return .event(.colorsChanged(colors), flow: sidecar.flow) }
            if let flow = sidecar.flow { return .event(.inputEcho(flow: flow), flow: nil) }
            return .nothing
        }
        if !resyncing, let next = nextOffset, frame.offset > next { return lost() }
        guard let decoded = TerminalAttachment.decodeAttachLine(name: name, line: line, surface: surface,
                                                                decoder: decoder),
              let event = sequencer.admit(decoded)
        else { return .nothing }
        return .event(event, flow: decoded.flow)
    }

    private mutating func appendBulk(_ chunk: TerminalFrameBytes, decoder: WireDecoder) -> TerminalFrameAdmission {
        guard var pending = bulk.take() else { return .nothing }
        switch pending.append(chunk, decoder: decoder) {
        case .waiting:
            bulk = pending
            return .nothing
        case .malformed:
            TerminalAttachment.noteUndecodable(pending.kind == .replay ? "replay frame" : "snapshot frame")
            return lost()
        case .complete(let meta, let raw):
            bulk = nil
            return completeBulk(meta, raw: raw, offset: pending.offset)
        }
    }

    private mutating func completeBulk(_ meta: PendingBulk.Meta, raw: Data, offset: UInt64) -> TerminalFrameAdmission {
        switch meta {
        case .replay(let state):
            guard adopt(state.surface) else { return .nothing }
            let replayLength = state.dataLen ?? 0
            let replay = raw.prefix(replayLength)
            let pending = raw.dropFirst(replayLength)
            restored(at: offset, snapshot: false)
            return .event(.replay(state.terminalReplay(data: replay, pending: pending)), flow: nil)
        case .snapshot(let snapshot):
            let ready = TerminalSnapshotFrame.Phase(rawValue: snapshot.phase) == .ready
            guard let frame = snapshot.frame(data: raw) else {
                guard ready else { return .nothing }  // a phase this view does not know
                TerminalAttachment.noteUndecodable("snapshot frame")
                return refusedReady()
            }
            if ready {
                guard adopt(snapshot.surface) else { return refusedReady() }
                restored(at: offset, snapshot: true)
            } else if !scoped(snapshot.surface) {
                return .nothing
            }
            guard let event = sequencer.admit(DecodedAttachLine(event: .snapshot(frame))) else { return .nothing }
            return .event(event, flow: nil)
        }
    }

    /// The screen is the one at `offset` (nil: the next OUTPUT names it): output continues from there, and a
    /// resync is over.
    private mutating func restored(at offset: UInt64?, snapshot: Bool) {
        nextOffset = offset
        outputRun?.deliveredEnd = nil  // output before the cut is on the restored screen
        resyncing = false
        snapshots = snapshot
    }

    /// Bytes were lost: a snapshot stream asks for a fresh READY once. A byte-replay stream cannot be repaired
    /// in place, and a loss while the fresh READY is due means the repair broke too: the view reattaches.
    private mutating func lost() -> TerminalFrameAdmission {
        bulk = nil
        guard snapshots, !resyncing else { return Self.reattach }
        resyncing = true
        return .resync(.gap)
    }

    /// A READY that does not decode or names another surface: the screen it should restore stays unknown.
    /// It ends a resync, which no later READY is due to end; otherwise the screen before it stays.
    private func refusedReady() -> TerminalFrameAdmission {
        resyncing ? Self.reattach : .nothing
    }

    /// The view reattaches from a fresh screen, as on the daemon's `overflow`.
    private static let reattach = TerminalFrameAdmission.event(.closed(.overflow), flow: nil)

    private func scoped(_ id: SurfaceID?) -> Bool {
        id == nil || id == surface
    }

    /// Like ``scoped(_:)``, and an unresolved stream takes the surface its first REPLAY or READY names.
    private mutating func adopt(_ id: SurfaceID?) -> Bool {
        if surface == TerminalAttachment.unresolvedSurface, let id { surface = id }
        return scoped(id)
    }
}

extension TerminalAttachFrameDecoder {
    /// Contiguous OUTPUT frames back to back: the chunks of one output, or outputs with no sidecar between.
    /// An output's sidecar comes after its last chunk with the aux of its first (cmux-tui `attach_frames.rs`).
    struct OutputRun: Sendable {
        /// The aux of the run's first OUTPUT.
        var start: UInt64
        /// The offset after the run's last byte.
        var end: UInt64
        /// The offset after the last byte of the run that reached the view; nil while none has.
        var deliveredEnd: UInt64?

        /// Whether the sidecar with aux `offset` is of output in this run that reached the view.
        func carries(sidecarAt offset: UInt64) -> Bool {
            guard let deliveredEnd else { return false }
            return start <= offset && offset < deliveredEnd
        }
    }

    /// What the view's attachment does with the admissions the queue does not take itself.
    struct Delivery: Sendable {
        /// A `size-state` and this view's participant in it (the attachment orders them by generation).
        var sizeState: @Sendable (TerminalSizeState, String?) -> Void
        /// Sends `snapshot-request` for this stream, and calls the second argument (once, on any thread) when
        /// the request cannot be sent or the host refuses it (`LineTransport.sendNoReply`'s `onError`).
        var requestSnapshot: @Sendable (SnapshotRequestReason, _ failed: @escaping @Sendable () -> Void) -> Void
        /// The typing probe's decode mark for output, and for the key press it echoes when known.
        var outputDecoded: @Sendable (UInt64?) -> Void
    }

    /// Reader thread. Hands one admission to the view's queue in stream order, as a decoded attach line is:
    /// output stays a slice of its read buffer, a key press's echo rides behind its chunk, `closed` ends the
    /// stream, and a gap asks the host for a fresh READY; when that request fails no READY is due, so the
    /// stream ends with `overflow` and the view reattaches.
    static func deliver(_ admission: TerminalFrameAdmission, to queue: TerminalEventQueue, delivery: Delivery) {
        switch admission {
        case .nothing:
            return
        case .output(let span):
            delivery.outputDecoded(nil)
            queue.push(span)
        case .event(.sizeState(let state, let participant), _):
            delivery.sizeState(state, participant)
        case .event(.closed(let reason), _):
            queue.finish(.closed(reason))
        case .event(.inputEcho(let flow), _):
            delivery.outputDecoded(flow)
            queue.pushWithoutWaiting(.inputEcho(flow: flow))
        case .event(.output(let data, let colors), let flow):  // an `output` line
            delivery.outputDecoded(flow)
            queue.push(.output(data, colors: colors))
            guard let flow else { return }
            queue.pushWithoutWaiting(.inputEcho(flow: flow))
        case .event(let event, let flow):
            queue.push(event)
            guard let flow else { return }
            delivery.outputDecoded(flow)
            queue.pushWithoutWaiting(.inputEcho(flow: flow))
        case .resync(let reason):
            delivery.requestSnapshot(reason) { queue.finish(.closed(.overflow)) }
        }
    }
}
