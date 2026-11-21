import Foundation
/// Evicted terminals' last frames (`TerminalLastFrame`), oldest dropped first past the bound: their own bytes within
/// 1/32 of physical memory (``byteBudget(physicalBytes:)``; Chrome sets its memory limits from physical memory too),
/// at most ``maxFrames``, and never fewer than the warm set's count (that floor wins over the budget). Each frame is one drawable at its pane's size
/// (a pane of a 3 x 4 grid on a 2x display: about 2 MB; a full window: about 26 MB), volatile while it waits, so
/// memory pressure takes its pages first (no policy of ours under pressure). A closed tab's frame goes with the tab
/// (`TabContentCache.release`).
@MainActor
public struct TerminalLastFrames {
    public init() {}

    private var frames: [String: TerminalLastFrame] = [:]
    /// Keys in eviction order, oldest first (at most ``maxFrames``: O(bound) edits).
    private var order: [String] = []
    /// The kept frames' bytes (``TerminalLastFrame/bytes``).
    public private(set) var storedBytes: UInt64 = 0
    /// What each eviction kept and each re-attach showed (`debug.surfaces` last_frames).
    public private(set) var outcomes: [String: Int] = [:]

    public var count: Int { frames.count }

    public subscript(key: String) -> TerminalLastFrame? { frames[key] }

    /// `key`'s frame for a hover card or drag thumbnail: only one whose terminal had output (a new
    /// shell's prompt has no picture, Leo 2026-10-13); every kept frame still shows at the reveal.
    public func preview(_ key: String) -> TerminalLastFrame? { frames[key].flatMap { $0.showsOutput ? $0 : nil } }

    /// Keeps `frame` for `key`; returns the frames the bound dropped, oldest first.
    mutating func insert(_ frame: TerminalLastFrame, for key: String, floor: Int, budget: UInt64) -> [(key: String, frame: TerminalLastFrame)] {
        _ = remove(key)
        frames[key] = frame
        order.append(key)
        storedBytes += frame.bytes
        return trim(floor: floor, budget: budget)
    }

    @discardableResult
    public mutating func remove(_ key: String) -> TerminalLastFrame? {
        guard let frame = frames.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        storedBytes -= frame.bytes
        return frame
    }

    /// Drops the oldest frames while more than `floor` are kept and they pass `budget` bytes or ``maxFrames``;
    /// returns them.
    mutating func trim(floor: Int, budget: UInt64) -> [(key: String, frame: TerminalLastFrame)] {
        var excess = 0
        var bytes = storedBytes
        while order.count - excess > max(0, floor), bytes > budget || order.count - excess > Self.maxFrames {
            bytes -= frames[order[excess]]?.bytes ?? 0
            excess += 1
        }
        guard excess > 0 else { return [] }
        let dropped = order.prefix(excess).compactMap { key in frames.removeValue(forKey: key).map { (key: key, frame: $0) } }
        order.removeFirst(excess)
        storedBytes = bytes
        return dropped
    }

    public mutating func note(_ outcome: String) { outcomes[outcome, default: 0] += 1 }

    /// The bytes evicted terminals' frames may hold: 1/32 of physical memory (16 GB: 512 MiB, about 230 panes of a
    /// 3 x 4 grid or 20 full windows on a 2x display; 64 GB: 2 GiB). The frames are volatile
    /// (``TerminalFramePurgeability``), so memory pressure takes their pages with no policy of ours. SWITCH FRAMES
    /// SF-2: bounded by the warm set alone (8 on a 16 GB Mac), a frame was dropped 4 switches after its eviction;
    /// STATUS 7963: counted at a full window's 24 MiB each, 29 frames, so a switch to a 12-pane workspace drew empty
    /// panes for about 220 ms.
    public static func byteBudget(physicalBytes: UInt64) -> UInt64 { physicalBytes / 32 }

    /// The most frames kept, whatever their size (each edit is O(count)).
    public static let maxFrames = 512

    /// The warm set evicts `session` (`key`), still in its window: keeps its frame, unless the
    /// eviction is a pressure drop (`atOnce`). `capacity` is the warm set's; the store keeps more
    /// (``byteBudget(physicalBytes:)``). Whatever the screen holds: the frame is what the pane
    /// shows when a switch shows it again (SWITCH FRAMES SF-2: a one-line screen kept no frame, so the
    /// switch frame showed an empty pane). Whether it is worth a hover picture is the frame's own
    /// ``TerminalLastFrame/showsOutput``.
    public mutating func evict(_ session: TerminalSession, key: String, capacity: Int, atOnce: Bool) {
        remove(key)
        guard !atOnce, capacity > 0 else { return note("evicted_at_once") }
        guard let frame = TerminalLastFrame(of: session, showsOutput: session.showsOutput) else { return note("evicted_no_frame") }
        note("kept")
        keep(frame, for: key, warm: capacity, physicalBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// Keeps `frame` for `key` within the store's bound for a warm set of `warm` on a Mac with `physicalBytes`.
    mutating func keep(_ frame: TerminalLastFrame, for key: String, warm: Int, physicalBytes: UInt64) {
        for _ in insert(frame, for: key, floor: warm, budget: Self.byteBudget(physicalBytes: physicalBytes)) { note("dropped") }
    }

    /// `key`'s new session draws now: it shows the frame that waits for it, if any.
    public mutating func show(_ key: String, on session: TerminalSession) {
        guard let frame = remove(key) else { return }
        note(session.showLastFrame(frame) ?? "shown")
    }

    /// `debug.surfaces` last_frames: the outcome counts, the frames stored now and their MiB.
    public var report: [String: Int] { outcomes.merging(["stored": count, "stored_mib": Int(storedBytes >> 20)]) { $1 } }
}
