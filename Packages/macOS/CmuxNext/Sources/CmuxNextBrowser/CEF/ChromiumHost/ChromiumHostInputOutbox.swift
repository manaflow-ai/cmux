#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.

/// Input frames to the Chromium host that its socket has not taken yet.
///
/// Every frame is written at once: cmux adds no display-tick wait, the
/// renderer aligns input to its own frames, as Chrome's browser process sends
/// input to the renderer as it comes (`content/browser/renderer_host/input/`).
/// Frames wait here only while the socket is full, and, after the first wheel
/// of a scroll, later wheels until the host acknowledges it.
///
/// - A newer pointer move or drag replaces a waiting one, wheel deltas add
///   into the waiting wheel and a newer geometry replaces a waiting one, each
///   only at the tail: the host's own `FrameQueue::Coalesce`
///   (`ChromiumHost/src/chromium_host_wire.h`). The order of moves, clicks,
///   keys and geometry stays the order sent, and a host that stops reading
///   holds at most one move between two discrete frames.
/// - Every other frame waits in order, at most ``discreteLimit``; one more
///   ends the connection.
/// - A partly written frame keeps its unwritten bytes at the front, as Mojo's
///   `ChannelPosix` keeps the offset of a partly written message
///   (`mojo/core/channel_posix.cc`), so the stream never breaks mid-frame.
/// - While the first wheel of a sequence waits for the host's ACK, later
///   wheels collapse into one held wheel that queues on the ACK: one wheel in
///   flight, as in `content/browser/renderer_host/input/mouse_wheel_event_queue.cc`
///   (keys sent meanwhile go first there too).
nonisolated struct ChromiumHostInputOutbox: Sendable {
    /// Discrete frames (keys, clicks, focus, navigation) that may wait.
    static let discreteLimit = 4_096
    /// Every waiting frame: a move whose buttons or modifiers changed does not
    /// fold into the one before it.
    static let frameLimit = 2 * discreteLimit

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

    private var frames: [ChromiumHostFrame] = []
    /// Frames before `head` are written; the array empties when drained or mostly written.
    private var head = 0
    /// The frame being written, and how many of its bytes the socket took.
    private var front: [UInt8] = []
    private var frontOffset = 0
    private(set) var discreteCount = 0
    /// The wheels sent while a sequence's first wheel waits for its ACK, summed.
    private(set) var heldWheel: ChromiumHostFrame?
    private(set) var awaitsWheelAck = false
    /// Frames folded into a waiting one since the connection opened.
    private(set) var coalesced: UInt64 = 0

    /// Frames that wait for the socket, the partly written one not counted.
    var waitingCount: Int { frames.count - head }
    /// Waiting pointer moves, wheels and geometry, the held wheel counted.
    var coalescibleCount: Int { waitingCount - discreteCount + (heldWheel == nil ? 0 : 1) }
    /// True while bytes wait for the socket.
    var hasUnwritten: Bool { frontOffset < front.count || head < frames.count }

    /// Queues `frame` behind every waiting frame, or folds it into the last
    /// one. False, with nothing queued, when the queue is full.
    mutating func push(_ frame: ChromiumHostFrame) -> Bool {
        if awaitsWheelAck, frame.rawKind == ChromiumHostFrame.Kind.wheel.rawValue {
            guard var held = heldWheel else {
                heldWheel = frame
                return true
            }
            if Self.fold(frame, into: &held) {
                heldWheel = held
                coalesced += 1
                return true
            }
            // Its modifiers changed: the summed wheel goes now, the new one is held.
            heldWheel = frame
            return append(held)
        }
        if head < frames.count, Self.fold(frame, into: &frames[frames.count - 1]) {
            coalesced += 1
            return true
        }
        return append(frame)
    }

    /// The first wheel of a sequence was queued: later wheels are held until
    /// ``wheelAcknowledged()``.
    mutating func holdWheelsUntilAck() {
        awaitsWheelAck = true
    }

    /// The host took the first wheel: the held wheel queues, and wheels go at
    /// once again. False when the queue is full.
    mutating func wheelAcknowledged() -> Bool {
        awaitsWheelAck = false
        guard let held = heldWheel else { return true }
        heldWheel = nil
        return push(held)
    }

    /// Writes waiting frames, oldest first, while `write` takes them. Each
    /// pass writes some bytes or returns, so it ends within the waiting bytes.
    mutating func flush(_ write: (UnsafeRawBufferPointer) -> WriteOutcome) -> FlushResult {
        while hasUnwritten {
            if frontOffset == front.count {
                let next = frames[head]
                head += 1
                if !Self.isCoalescible(next) { discreteCount -= 1 }
                front = next.encoded()
                frontOffset = 0
            }
            let offset = frontOffset
            let outcome = front.withUnsafeBytes { write(UnsafeRawBufferPointer(rebasing: $0[offset...])) }
            switch outcome {
            case .wrote(let count) where count > 0:
                frontOffset += count
            case .interrupted:
                break  // EINTR: the same bytes again
            case .wouldBlock:
                compactIfSparse()
                return .blocked
            case .wrote, .failed:
                return .failed
            }
        }
        frames.removeAll(keepingCapacity: true)
        head = 0
        return .drained
    }

    private mutating func append(_ frame: ChromiumHostFrame) -> Bool {
        let discrete = !Self.isCoalescible(frame)
        guard waitingCount < Self.frameLimit, !discrete || discreteCount < Self.discreteLimit else { return false }
        if discrete { discreteCount += 1 }
        frames.append(frame)
        return true
    }

    /// Drops written slots once they are most of the array; O(waiting), at most once per as many writes.
    private mutating func compactIfSparse() {
        guard head > 64, head * 2 > frames.count else { return }
        frames.removeFirst(head)
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
