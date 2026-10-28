import AppKit

/// `PointerHover`'s targets filed by window (cx-8w027.10 item c): a refresh reads one window's
/// targets, the targets without a window and the targets that hover now. A target is filed under
/// the window its view is in when the index last saw it: at a refresh that visits it, at its own
/// enter, exit or `refresh()`, and at every key-window change. A refresh files each visited target
/// again, so a view that left the window moves to `unplaced`, one that came in from `unplaced` is
/// filed under its window, and one found in another window refreshes that window too.
@MainActor
final class PointerHoverTargetIndex {
    private struct Weak {
        weak var value: PointerHover?
    }

    private struct Bucket {
        weak var window: NSWindow?
        var targets: [ObjectIdentifier: Weak] = [:]
    }

    private var buckets: [ObjectIdentifier: Bucket] = [:]
    /// Targets whose view had no window when last seen.
    private var unplaced: [ObjectIdentifier: Weak] = [:]
    /// Targets that hover now (a handful).
    private var hovering: [ObjectIdentifier: Weak] = [:]
    private var nextOrder: UInt64 = 0

    func insert(_ target: PointerHover) {
        nextOrder &+= 1
        target.order = nextOrder
        target.indexedWindow = nil
        unplaced[ObjectIdentifier(target)] = Weak(value: target)
        place(target)
    }

    func noteHovering(_ target: PointerHover, _ hovers: Bool) {
        hovering[ObjectIdentifier(target)] = hovers ? Weak(value: target) : nil
    }

    /// The windows of the targets that hover now (a handful); freed targets drop out.
    func hoveringWindows() -> [NSWindow] {
        var windows: [NSWindow] = []
        for (id, entry) in hovering {
            guard let target = entry.value else {
                hovering[id] = nil
                continue
            }
            if let window = target.viewWindow, !windows.contains(where: { $0 === window }) { windows.append(window) }
        }
        return windows
    }

    /// Files `target` under the window its view is in now; returns that window when the target
    /// moved into it.
    @discardableResult
    func place(_ target: PointerHover) -> NSWindow? {
        let key = ObjectIdentifier(target)
        let window = target.viewWindow
        let now = window.map(ObjectIdentifier.init)
        let filed = now.map { buckets[$0]?.window === window && buckets[$0]?.targets[key] != nil } ?? (unplaced[key] != nil)
        guard now != target.indexedWindow || !filed else { return nil }
        if let old = target.indexedWindow {
            buckets[old]?.targets[key] = nil
            if buckets[old]?.targets.isEmpty == true { buckets[old] = nil }
        }
        unplaced[key] = nil
        target.indexedWindow = now
        guard let window, let now else {
            unplaced[key] = Weak(value: target)
            return nil
        }
        // A window identifier reused by a new window: the old window's targets go back to `unplaced`.
        if let bucket = buckets[now], bucket.window !== window { dropBucket(now) }
        if buckets[now] == nil { buckets[now] = Bucket(window: window) }
        buckets[now]?.targets[key] = Weak(value: target)
        return window
    }

    /// Every target filed under its window again; freed targets and closed windows drop out.
    func placeAll() {
        for (key, bucket) in buckets where bucket.window == nil { dropBucket(key) }
        let all = buckets.values.flatMap { $0.targets.values.compactMap(\.value) } + unplaced.values.compactMap(\.value)
        for (key, bucket) in buckets { buckets[key]?.targets = bucket.targets.filter { $0.value.value != nil } }
        unplaced = unplaced.filter { $0.value.value != nil }
        for target in all { place(target) }
    }

    /// The targets a refresh of `window` reads, in creation order with the hovering ones first
    /// (a hover that ends runs before one that starts), each filed again; and the other windows
    /// a visited target was found in. Freed targets drop out.
    func candidates(in window: NSWindow) -> (targets: [PointerHover], moved: [NSWindow]) {
        let key = ObjectIdentifier(window)
        if let bucket = buckets[key], bucket.window !== window { dropBucket(key) }
        var found: [ObjectIdentifier: PointerHover] = [:]
        for (id, entry) in buckets[key]?.targets ?? [:] {
            if let target = entry.value { found[id] = target } else { buckets[key]?.targets[id] = nil }
        }
        for (id, entry) in unplaced {
            if let target = entry.value { found[id] = target } else { unplaced[id] = nil }
        }
        for (id, entry) in hovering {
            if let target = entry.value { found[id] = target } else { hovering[id] = nil }
        }
        var moved: [NSWindow] = []
        for target in found.values {
            if let other = place(target), other !== window, !moved.contains(where: { $0 === other }) { moved.append(other) }
        }
        // One integer per target: a tuple compare goes through the runtime's tuple metadata on
        // every comparison, half of a Cmd-Tab's main-thread time with a few thousand targets.
        let targets = found.values.map { (key: ($0.isHovering ? 0 : 1 << 63) | $0.order, target: $0) }
            .sorted { $0.key < $1.key }.map(\.target)
        return (targets, moved)
    }

    /// Drops the bucket under `key` (its window closed, or a new window reuses the identifier):
    /// its live targets go back to `unplaced`, to be filed again where their views are.
    private func dropBucket(_ key: ObjectIdentifier) {
        guard let bucket = buckets.removeValue(forKey: key) else { return }
        for (id, entry) in bucket.targets {
            guard let target = entry.value else { continue }
            target.indexedWindow = nil
            unplaced[id] = entry
        }
    }
}
