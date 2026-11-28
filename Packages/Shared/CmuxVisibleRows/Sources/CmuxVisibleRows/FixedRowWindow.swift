/// The rows a list of fixed-height rows mounts, and which of them a change makes it configure again (Leo 2026-11-18,
/// ask-1105ee4cc6: "we draw the visible area, right?"). No AppKit or UIKit, so its math is tested on every platform;
/// the Cloud Team sessions list (CmuxNextCloudUI) keeps its row views by the keys `remount` reads.
// lint:allow namespace-type: pure row-window math over value inputs, shared by the platforms; no receiver owns it yet.
public enum FixedRowWindow {
    /// The rows in the viewport plus one viewport above and one below, clamped to `0..<count`. A viewport of no height
    /// (a list not laid out yet) reads as `fallbackHeight`, so the first pass mounts a screenful and not nothing.
    public static func range(count: Int, top: Double, height: Double, rowHeight: Double, fallbackHeight: Double) -> Range<Int> {
        guard count > 0, rowHeight > 0 else { return 0..<0 }
        let viewport = height > 0 ? height : fallbackHeight
        let first = max(0, Int((top - viewport) / rowHeight))
        let end = min(count, Int(((top + viewport * 2) / rowHeight).rounded(.up)))
        return first < end ? first..<end : 0..<0
    }

    /// One pass over the mounted rows: which window positions get a row and which of those need configuring.
    public struct Remount<Key: Hashable>: Equatable {
        /// Window positions (offsets into the `window` passed in) that get a row, in order; a key seen earlier in the
        /// window is skipped, so one key never holds two rows.
        public var placed: [Int] = []
        /// The positions in `placed` whose key was not mounted, or whose item changed: the only rows configured.
        public var configure: [Int] = []
        /// Mounted keys the window no longer holds: their rows go spare.
        public var released: [Key] = []
    }

    /// Matches the window's items to the mounted ones by key. Reads the window and the mounted rows once each, never
    /// the whole list, so its cost is the rows on screen.
    public static func remount<Key: Hashable, Item: Equatable>(
        window: [(key: Key, item: Item)], mounted: [Key: Item]
    ) -> Remount<Key> {
        var plan = Remount<Key>()
        var seen = Set<Key>()
        seen.reserveCapacity(window.count)
        for (position, entry) in window.enumerated() where seen.insert(entry.key).inserted {
            plan.placed.append(position)
            if mounted[entry.key] != entry.item { plan.configure.append(position) }
        }
        plan.released = mounted.keys.filter { !seen.contains($0) }
        return plan
    }
}
