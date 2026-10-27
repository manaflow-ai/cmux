#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.

/// Input frames to the Chromium host that its socket has not taken yet,
/// encoded and contiguous, oldest first.
///
/// Every frame is written at once: cmux adds no display-tick wait, the
/// renderer aligns input to its own frames, as Chrome's browser process sends
/// input to the renderer as it comes (`content/browser/renderer_host/input/`).
/// Frames wait here only while the socket is full.
///
/// - Between two discrete frames each coalescible kind (pointer move or drag,
///   wheel, geometry) has one latest-wins slot: a newer move or geometry
///   replaces its waiting one, wheel deltas add into the waiting wheel. Chrome's
///   browser side queues each input class on its own too (`input_router_impl.cc`,
///   `mouse_wheel_event_queue.cc`), so a host that stops reading holds at most
///   three coalescible frames between two discrete ones, whatever their mix.
/// - Every other frame waits in order, at most ``discreteLimit`` of them and
///   ``byteLimit`` bytes in all; one more ends the connection.
/// - A partly written frame keeps its unwritten bytes at the front, as Mojo's
///   `ChannelPosix` keeps the offset of a partly written message
///   (`mojo/core/channel_posix.cc`), so the stream never breaks mid-frame.
/// - One ``flush(_:)`` is one `write` of every waiting byte.
///
/// The host's ACK of a sequence's first wheel (one wheel in flight, as in
/// `mouse_wheel_event_queue.cc`) comes with the host's ACK frame, task
/// p01-process-042; until then wheels go at once like moves.
nonisolated struct ChromiumHostInputOutbox: Sendable {
    /// Discrete frames (keys, clicks, focus, navigation) that may wait.
    static let discreteLimit = 4_096
    /// Bytes that may wait: four kernel send buffers, as the control channel's
    /// quota is a byte count too. Navigation and text payloads count.
    static let byteLimit = 4 * Int(ChromiumHostConnection.sendBuffer)

    /// What one `write` did.
    enum WriteOutcome: Equatable, Sendable {
        case wrote(Int)
        case wouldBlock
        case interrupted
        case failed
    }

    enum FlushResult: Equatable, Sendable {
        case drained
        /// The socket is full: the rest waits for it to take more.
        case blocked
        case failed
    }

    /// One waiting frame: where its bytes start, and whether it is discrete.
    private struct Entry: Sendable {
        var start: Int
        var discrete: Bool
    }

    /// A coalescible kind's waiting frame and its entry.
    private struct Slot: Sendable {
        var frame: ChromiumHostFrame
        var entry: Int
    }

    /// The encoded frames; bytes before `written` are in the socket.
    private var bytes: [UInt8] = []
    private var written = 0
    private var entries: [Entry] = []
    /// Entries before `head` have bytes in the socket: they no longer wait.
    private var head = 0
    /// The move, wheel and geometry slots of the run after the last discrete frame.
    private var move: Slot?
    private var wheel: Slot?
    private var geometry: Slot?
    private(set) var discreteCount = 0
    /// Frames folded into a waiting one since the connection opened.
    private(set) var coalesced: UInt64 = 0
    /// Bytes the socket took since the connection opened.
    private(set) var taken: UInt64 = 0

    /// Frames that wait for the socket, the partly written one not counted.
    var waitingCount: Int { entries.count - head }
    /// Waiting pointer moves, wheels and geometry.
    var coalescibleCount: Int { waitingCount - discreteCount }
    /// Bytes that wait for the socket, the partly written frame's rest counted.
    var waitingBytes: Int { bytes.count - written }
    /// True while bytes wait for the socket.
    var hasUnwritten: Bool { written < bytes.count }

    /// Queues `frame` behind every waiting frame, or folds it into its kind's
    /// slot. False, with nothing queued, when the queue is full.
    mutating func push(_ frame: ChromiumHostFrame) -> Bool {
        if fold(frame) {
            coalesced += 1
            return true
        }
        let discrete = !Self.isCoalescible(frame)
        let size = ChromiumHostFrame.headerSize + frame.payload.count
        guard waitingBytes + size <= Self.byteLimit, !discrete || discreteCount < Self.discreteLimit else { return false }
        let entry = Entry(start: bytes.count, discrete: discrete)
        bytes.append(contentsOf: frame.encoded())
        entries.append(entry)
        let slot = Slot(frame: frame, entry: entries.count - 1)
        if discrete {
            discreteCount += 1
            move = nil
            wheel = nil
            geometry = nil
        } else {
            switch frame.kind {
            case .mouse: move = slot
            case .wheel: wheel = slot
            default: geometry = slot
            }
        }
        return true
    }

    /// Writes the waiting bytes with one `write` (again on EINTR). `write` gets a view of the outbox's own
    /// bytes, valid only during its call.
    @safe
    mutating func flush(_ write: (UnsafeRawBufferPointer) -> WriteOutcome) -> FlushResult {
        while hasUnwritten {
            let offset = written
            // SAFETY: a view of `bytes[offset...]`, inside the array, valid for the call; `write` keeps none of it.
            let outcome = unsafe bytes.withUnsafeBytes { unsafe write(UnsafeRawBufferPointer(rebasing: $0[offset...])) }
            switch outcome {
            case .wrote(let count) where count > 0:
                written += count
                taken += UInt64(count)
                retireWritten()
                if hasUnwritten {  // a short write: the socket is full
                    compactIfSparse()
                    return .blocked
                }
            case .interrupted:
                continue  // EINTR: the same bytes again
            case .wouldBlock:
                return .blocked
            case .wrote, .failed:
                return .failed
            }
        }
        bytes.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
        written = 0
        head = 0
        move = nil
        wheel = nil
        geometry = nil
        return .drained
    }

    /// Folds `frame` into its kind's slot when the slot's frame still waits
    /// whole; it is rewritten in place (a foldable frame has no payload, so its
    /// encoding keeps its length).
    private mutating func fold(_ frame: ChromiumHostFrame) -> Bool {
        let slot: Slot?
        switch frame.kind {
        case .mouse: slot = move
        case .wheel: slot = wheel
        case .geometry: slot = geometry
        default: return false
        }
        guard var slot, slot.entry >= head, Self.fold(frame, into: &slot.frame) else { return false }
        let start = entries[slot.entry].start
        bytes.replaceSubrange(start..<(start + ChromiumHostFrame.headerSize), with: slot.frame.encoded())
        switch frame.kind {
        case .mouse: move = slot
        case .wheel: wheel = slot
        default: geometry = slot
        }
        return true
    }

    /// Entries whose first byte is in the socket no longer wait.
    private mutating func retireWritten() {
        while head < entries.count, entries[head].start < written {
            if entries[head].discrete { discreteCount -= 1 }
            head += 1
        }
    }

    /// Drops the written bytes once they outnumber the waiting ones: a move
    /// of fewer bytes than were written since the last one.
    private mutating func compactIfSparse() {
        guard written >= 64 * 1024, written * 2 > bytes.count else { return }
        let shift = written, retired = head
        // Not compacting is always correct: the bytes and entries stay where they are until the next pass.
        guard shift <= bytes.count, retired <= entries.count else { return }
        bytes.removeFirst(shift)
        // A partly written frame's rest is now at the front; its entry is retired with the others before `head`.
        entries.removeFirst(retired)
        written = 0
        for index in entries.indices { entries[index].start -= shift }
        func rebased(_ slot: Slot?) -> Slot? {
            guard let slot, slot.entry >= retired else { return nil }
            return Slot(frame: slot.frame, entry: slot.entry - retired)
        }
        move = rebased(move)
        wheel = rebased(wheel)
        geometry = rebased(geometry)
        head = 0
    }

    /// A pointer move or drag (mouse phase 0), a wheel, or geometry: a newer one only updates it.
    static func isCoalescible(_ frame: ChromiumHostFrame) -> Bool {
        switch frame.kind {
        case .mouse: frame.v[2] == 0
        case .wheel, .geometry: true
        default: false
        }
    }

    /// Folds `next` into `waiting` when it only updates it: the host's
    /// `FrameQueue::Coalesce`. A wheel folds only into a wheel that differs in
    /// nothing but position, deltas and time, so a wheel of another phase or
    /// with other modifiers starts a new entry.
    static func fold(_ next: ChromiumHostFrame, into waiting: inout ChromiumHostFrame) -> Bool {
        guard next.rawKind == waiting.rawKind, next.payload.isEmpty, waiting.payload.isEmpty else { return false }
        switch next.kind {
        case .mouse:
            guard next.v[2] == 0, waiting.v[2] == 0, next.flags == waiting.flags, next.v[5] == waiting.v[5] else { return false }
            waiting = next  // the newest position, buttons and event time
            return true
        case .wheel:
            guard next.flags == waiting.flags, next.v[4] == waiting.v[4], next.v[5] == waiting.v[5], next.t1 == waiting.t1,
                  next.ch == waiting.ch, next.unmod == waiting.unmod, next.seq == waiting.seq else { return false }
            let dx = waiting.v[2], dy = waiting.v[3]
            waiting = next  // the newest position and event time, the summed deltas
            waiting.v[2] = saturatingAdd(dx, next.v[2])
            waiting.v[3] = saturatingAdd(dy, next.v[3])
            return true
        case .geometry:
            waiting = next
            return true
        default:
            return false
        }
    }

    private static func saturatingAdd(_ a: Int32, _ b: Int32) -> Int32 {
        Int32(clamping: Int64(a) + Int64(b))
    }
}
#endif
