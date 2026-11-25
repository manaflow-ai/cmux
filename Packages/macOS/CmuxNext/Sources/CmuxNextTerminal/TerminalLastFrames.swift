import Foundation
/// Evicted terminals' last frames (`TerminalLastFrame`), oldest dropped first past the bound
/// (``capacity(warm:)``: the warm capacity plus what 1/32 of physical memory holds). Each frame is
/// one full-resolution drawable (about 24 MB for a large pane on a 2x display), volatile while it
/// waits, so memory pressure takes its pages first (no policy of ours under pressure). A closed
/// tab's frame goes with the tab (`TabContentCache.release`).
@MainActor
public struct TerminalLastFrames {
    public init() {}

    private var frames: [String: TerminalLastFrame] = [:]
    /// Keys in eviction order, oldest first (at most ``capacity(warm:)``, 152: O(bound) edits).
    private var order: [String] = []
    /// What each eviction kept and each re-attach showed (`debug.surfaces` last_frames).
    public private(set) var outcomes: [String: Int] = [:]

    public var count: Int { frames.count }

    public subscript(key: String) -> TerminalLastFrame? { frames[key] }

    /// `key`'s frame for a hover card or drag thumbnail: only one whose terminal had output (a new
    /// shell's prompt has no picture, Leo 2026-10-13); every kept frame still shows at the reveal.
    public func preview(_ key: String) -> TerminalLastFrame? { frames[key].flatMap { $0.showsOutput ? $0 : nil } }

    /// Keeps `frame` for `key`; returns the frames the bound dropped.
    mutating func insert(_ frame: TerminalLastFrame, for key: String, capacity: Int) -> [(key: String, frame: TerminalLastFrame)] {
        _ = remove(key)
        frames[key] = frame
        order.append(key)
        return trim(to: capacity)
    }

    @discardableResult
    public mutating func remove(_ key: String) -> TerminalLastFrame? {
        guard let frame = frames.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return frame
    }

    /// Drops the oldest frames past `capacity`; returns them.
    mutating func trim(to capacity: Int) -> [(key: String, frame: TerminalLastFrame)] {
        let excess = order.count - max(0, capacity)
        guard excess > 0 else { return [] }
        let dropped = order.prefix(excess).compactMap { key in frames.removeValue(forKey: key).map { (key: key, frame: $0) } }
        order.removeFirst(excess)
        return dropped
    }

    public mutating func note(_ outcome: String) { outcomes[outcome, default: 0] += 1 }

    /// How many evicted terminals keep a last frame: the warm set's hidden terminals plus the frames 1/32 of
    /// physical memory holds at ``frameCostBytes`` each (16 GB: 21, 64 GB: 85; at most 128). The frames are volatile
    /// (``TerminalFramePurgeability``), so memory pressure takes their pages with no policy of ours. SWITCH FRAMES
    /// SF-2: bounded by the warm set alone (8 on a 16 GB Mac), a terminal's frame was dropped 4 switches after its
    /// eviction in a 9-workspace, 18-terminal session, and every switch back showed an empty pane.
    public static func capacity(warm: Int) -> Int { capacity(warm: warm, physicalBytes: ProcessInfo.processInfo.physicalMemory) }

    /// ``capacity(warm:)`` for a Mac with `physicalBytes` of memory.
    public static func capacity(warm: Int, physicalBytes: UInt64) -> Int {
        guard warm > 0 else { return 0 }
        return warm + min(128, Int((physicalBytes / 32) / frameCostBytes))
    }

    /// One frame of a large pane on a 2x display (about 1800 x 1100 points, BGRA): 24 MB.
    public static let frameCostBytes: UInt64 = 24 << 20

    /// The warm set evicts `session` (`key`), still in its window: keeps its frame, unless the
    /// eviction is a pressure drop (`atOnce`). `capacity` is the warm set's; the store keeps more
    /// (``capacity(warm:)``). Whatever the screen holds: the frame is what the pane
    /// shows when a switch shows it again (SWITCH FRAMES SF-2: a one-line screen kept no frame, so the
    /// switch frame showed an empty pane). Whether it is worth a hover picture is the frame's own
    /// ``TerminalLastFrame/showsOutput``.
    public mutating func evict(_ session: TerminalSession, key: String, capacity: Int, atOnce: Bool) {
        remove(key)
        guard !atOnce, capacity > 0 else { return note("evicted_at_once") }
        guard let frame = TerminalLastFrame(of: session, showsOutput: session.showsOutput) else { return note("evicted_no_frame") }
        note("kept")
        for _ in insert(frame, for: key, capacity: Self.capacity(warm: capacity)) { note("dropped") }
    }

    /// `key`'s new session draws now: it shows the frame that waits for it, if any.
    public mutating func show(_ key: String, on session: TerminalSession) {
        guard let frame = remove(key) else { return }
        note(session.showLastFrame(frame) ?? "shown")
    }

    /// `debug.surfaces` last_frames: the outcome counts and the frames stored now.
    public var report: [String: Int] { outcomes.merging(["stored": count]) { $1 } }
}
