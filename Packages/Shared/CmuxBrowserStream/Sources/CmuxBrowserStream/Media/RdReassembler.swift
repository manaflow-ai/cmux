public import Foundation

/// Viewer-side reassembly of one display stream (cmux-rd-core `Reassembler`
/// without FEC). Collects shards, releases a frame only after the frame it
/// references was released, and reports loss when a reference can no longer
/// arrive, so a frame that predicts from a lost frame is never decoded.
///
/// No timers: a missing reference is declared lost when `holdFrames`
/// complete frames are waiting for it (they keep arriving at the frame
/// rate) or when a keyframe lands past it.
public struct RdReassembler: Sendable {
    private struct Pending {
        var flags: RdFrameFlags
        var count: Int
        var shards: [Data?]
        var received = 0
    }

    public private(set) var lastReleased: UInt32 = 0
    /// Set when a loss broke the reference chain; cleared when a keyframe
    /// or a recovery frame is released.
    public private(set) var needsRecovery = false
    /// Frames lost since the last `takeLosses()`.
    public private(set) var lostFrames: [UInt32] = []

    private let holdFrames: Int
    private let maxPendingFrames: Int
    private var finishedThrough: UInt32 = 0
    private var pending: [UInt32: Pending] = [:]
    private var waiting: [UInt32: RdCompletedFrame] = [:]
    private var released: Set<UInt32> = []
    private var releasedOrder: [UInt32] = []

    public init(holdFrames: Int = 2, maxPendingFrames: Int = 64) {
        self.holdFrames = max(1, holdFrames)
        self.maxPendingFrames = maxPendingFrames
    }

    /// Adds one video datagram's header and payload; returns the frames that
    /// became decodable, in order.
    public mutating func push(_ header: RdDatagramHeader, payload: Data) -> [RdCompletedFrame] {
        guard header.kind == .video, header.frame > finishedThrough, waiting[header.frame] == nil else { return [] }
        var entry = pending[header.frame] ?? Pending(flags: header.flags, count: Int(header.count),
                                                     shards: Array(repeating: nil, count: Int(header.count)))
        guard entry.count == Int(header.count), Int(header.index) < entry.count else { return [] }
        if pending[header.frame] == nil, pending.count >= maxPendingFrames {
            return []
        }
        guard entry.shards[Int(header.index)] == nil else { return [] }
        entry.shards[Int(header.index)] = payload
        entry.received += 1
        guard entry.received == entry.count else {
            pending[header.frame] = entry
            return []
        }
        pending[header.frame] = nil
        var bytes = Data()
        for shard in entry.shards { bytes.append(shard ?? Data()) }
        guard let body = try? RdFrameBody(decoding: bytes) else {
            markLost(header.frame)
            return []
        }
        waiting[header.frame] = RdCompletedFrame(frame: header.frame, flags: entry.flags, body: body)
        return drain()
    }

    /// The frames lost since the last call (for feedback and diagnostics).
    public mutating func takeLosses() -> [UInt32] {
        defer { lostFrames.removeAll() }
        return lostFrames
    }

    /// Forgets everything (a new stream after a resize or a reconnect).
    public mutating func reset() {
        self = RdReassembler(holdFrames: holdFrames, maxPendingFrames: maxPendingFrames)
    }

    private mutating func drain() -> [RdCompletedFrame] {
        var out: [RdCompletedFrame] = []
        while let first = waiting.keys.min() {
            let frame = waiting[first]!
            if isReleasable(frame) {
                waiting[first] = nil
                release(frame)
                out.append(frame)
                continue
            }
            // A keyframe further on supersedes the broken chain before it.
            guard let key = waiting.values.filter(\.isKeyframe).map(\.frame).min() else { break }
            finish(through: key - 1)
        }
        if waiting.count >= holdFrames, let newest = waiting.keys.max() {
            // The references these frames wait for are not coming.
            needsRecovery = true
            finish(through: newest)
        }
        return out
    }

    private func isReleasable(_ frame: RdCompletedFrame) -> Bool {
        frame.isKeyframe || released.contains(frame.body.refFrame)
    }

    private mutating func release(_ frame: RdCompletedFrame) {
        if frame.isKeyframe || frame.flags.contains(.recovery) { needsRecovery = false }
        if frame.frame > finishedThrough {
            for lost in (finishedThrough + 1)..<frame.frame where !released.contains(lost) && waiting[lost] == nil {
                pending[lost] = nil
                markLost(lost)
            }
            finishedThrough = frame.frame
        }
        lastReleased = max(lastReleased, frame.frame)
        released.insert(frame.frame)
        releasedOrder.append(frame.frame)
        if releasedOrder.count > 64 {
            released.remove(releasedOrder.removeFirst())
        }
    }

    /// Ends every frame up to `frame`: pending shards and waiting frames are lost.
    private mutating func finish(through frame: UInt32) {
        guard frame > finishedThrough else { return }
        for number in (finishedThrough + 1)...frame where !released.contains(number) {
            pending[number] = nil
            waiting[number] = nil
            markLost(number)
        }
        finishedThrough = frame
    }

    private mutating func markLost(_ frame: UInt32) {
        guard !lostFrames.contains(frame) else { return }
        lostFrames.append(frame)
    }
}
