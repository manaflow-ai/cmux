/// Holds terminal grid reports until a view's size has stopped changing.
///
/// Every `resized` from the daemon makes the app rebuild a Ghostty surface
/// from a replay, so sending one per animation frame (layout springs, sidebar
/// width, live window resize) would be expensive. Reports are submitted as
/// they happen; `tick` runs once per display frame and releases a size after
/// it has been stable for `stableFrames` frames and no hold is active.
public struct ResizeSettle<Key: Hashable & Sendable, Size: Equatable & Sendable>: Sendable {
    struct Entry: Sendable {
        var size: Size
        var stableFor = 0
    }

    public let stableFrames: Int
    private var pending: [Key: Entry] = [:]

    public init(stableFrames: Int = 2) {
        self.stableFrames = max(1, stableFrames)
    }

    public var isIdle: Bool { pending.isEmpty }

    public mutating func submit(_ key: Key, size: Size) {
        if pending[key]?.size == size { return }
        pending[key] = Entry(size: size)
    }

    public mutating func cancel(_ key: Key) {
        pending[key] = nil
    }

    /// Advances one frame. `held` keys (for example a window in live resize)
    /// keep their pending size. Returns sizes to send now.
    public mutating func tick(held: Set<Key> = []) -> [(key: Key, size: Size)] {
        var ready: [(key: Key, size: Size)] = []
        for (key, entry) in pending {
            guard !held.contains(key) else {
                pending[key]?.stableFor = 0
                continue
            }
            let age = entry.stableFor + 1
            if age >= stableFrames {
                ready.append((key, entry.size))
                pending[key] = nil
            } else {
                pending[key]?.stableFor = age
            }
        }
        return ready
    }
}
