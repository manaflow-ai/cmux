import CmuxNextTerminal

/// Evicted terminals' last frames (`TerminalLastFrame`), oldest dropped first past `capacity`.
/// The bound is the warm set's terminal capacity: one frame costs about a sixth of a hidden
/// terminal (one of its three drawables, no grid or atlas), so the frames add at most a sixth of
/// the warm set's memory budget, and memory pressure lowers both together (critical keeps none).
@MainActor
struct TerminalLastFrames {
    private var frames: [String: TerminalLastFrame] = [:]
    /// Keys in eviction order, oldest first (at most `capacity`, 24: O(capacity) edits).
    private var order: [String] = []
    /// What each eviction kept and each re-attach showed (`debug.surfaces` last_frames).
    private(set) var outcomes: [String: Int] = [:]

    var count: Int { frames.count }

    subscript(key: String) -> TerminalLastFrame? { frames[key] }

    /// Keeps `frame` for `key`; returns the frames the bound dropped.
    mutating func insert(_ frame: TerminalLastFrame, for key: String, capacity: Int) -> [(key: String, frame: TerminalLastFrame)] {
        _ = remove(key)
        frames[key] = frame
        order.append(key)
        return trim(to: capacity)
    }

    @discardableResult
    mutating func remove(_ key: String) -> TerminalLastFrame? {
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

    mutating func note(_ outcome: String) { outcomes[outcome, default: 0] += 1 }
}
