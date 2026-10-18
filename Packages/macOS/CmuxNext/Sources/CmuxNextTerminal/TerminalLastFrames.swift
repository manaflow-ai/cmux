/// Evicted terminals' last frames (`TerminalLastFrame`), oldest dropped first past `capacity`.
/// The bound is the warm set's terminal capacity. Each frame is one full-resolution drawable
/// (about 20 MB for a full-screen Retina pane), volatile while it waits, so memory pressure
/// takes its pages first (no policy of ours under pressure). A closed tab's frame is never asked
/// for again: it ages out under the bound, volatile meanwhile.
@MainActor
public struct TerminalLastFrames {
    public init() {}

    private var frames: [String: TerminalLastFrame] = [:]
    /// Keys in eviction order, oldest first (at most `capacity`, 24: O(capacity) edits).
    private var order: [String] = []
    /// What each eviction kept and each re-attach showed (`debug.surfaces` last_frames).
    public private(set) var outcomes: [String: Int] = [:]

    public var count: Int { frames.count }

    public subscript(key: String) -> TerminalLastFrame? { frames[key] }

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

    /// The warm set evicts `session` (`key`), still in its window: keeps its frame, unless the
    /// eviction is a pressure drop (`atOnce`) or the terminal shows no output yet.
    public mutating func evict(_ session: TerminalSession, key: String, capacity: Int, atOnce: Bool) {
        remove(key)
        guard !atOnce, capacity > 0 else { return note("evicted_at_once") }
        guard session.showsOutput else { return note("evicted_no_output") }
        guard let frame = TerminalLastFrame(of: session) else { return note("evicted_no_frame") }
        note("kept")
        for _ in insert(frame, for: key, capacity: capacity) { note("dropped") }
    }

    /// `key`'s new session draws now: it shows the frame that waits for it, if any.
    public mutating func show(_ key: String, on session: TerminalSession) {
        guard let frame = remove(key) else { return }
        note(session.showLastFrame(frame) ?? "shown")
    }

    /// `debug.surfaces` last_frames: the outcome counts and the frames stored now.
    public var report: [String: Int] { outcomes.merging(["stored": count]) { $1 } }
}
