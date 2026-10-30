import AppKit

/// `PointerHover`'s targets by view, and the ones that hover now. A refresh of a window reads the
/// hovering targets (a handful) and the targets of the views under the pointer there, found by a
/// walk down the window's view tree along the pointer, as Chromium's `RootView` finds a mouse
/// move's handler (`GetEventHandlerForPoint`) and `Widget::SynthesizeMouseMoveEvent` replays the
/// last mouse location after a layout. It never reads every target: the index changes only when a
/// target is made or freed (O(1) each), and a view that moves into, out of or between windows
/// needs no notice, since the walk sees where the views are now.
///
/// Before (cx-8w027.10 item c), each refresh read every target of the window plus every target
/// whose view had no window (detached rows, the chrome of a closed tab, views made before their
/// window), filed each again and sorted them all; a sidebar layout pass refreshes, so every layout
/// pass cost every view the process kept, and the full suite's main thread spent its time there.
@MainActor
final class PointerHoverTargetIndex {
    private struct Weak {
        weak var value: PointerHover?
    }

    /// The targets of each view (one, now and then two), by the view's identifier.
    private var byView: [ObjectIdentifier: [Weak]] = [:]
    /// Targets that hover now (a handful).
    private var hovering: [ObjectIdentifier: Weak] = [:]
    private var nextOrder: UInt64 = 0
    /// The entry count at which freed entries are swept (a target freed off the main thread
    /// leaves its entry): twice the count after the last sweep, so sweeps cost O(1) a target.
    private var sweepAt = 256

    func insert(_ target: PointerHover, view: NSView) {
        nextOrder &+= 1
        target.order = nextOrder
        let key = ObjectIdentifier(view)
        // A freed view's identifier reused by this one: its old entries go.
        var entries = byView[key, default: []].filter { $0.value?.hoverView === view }
        entries.append(Weak(value: target))
        byView[key] = entries
        if byView.count >= sweepAt { sweep() }
    }

    /// A target is freed (its `deinit`, on the main thread): its entries drop out.
    func remove(_ target: ObjectIdentifier, view: ObjectIdentifier) {
        hovering[target] = nil
        guard let entries = byView[view] else { return }
        let live = entries.filter { $0.value != nil }
        byView[view] = live.isEmpty ? nil : live
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

    /// The targets a refresh of `window` reads: the ones that hover now, then the ones whose view
    /// is under the pointer in `window` (the enter or exit's own point while `event` is one of its
    /// window), each group in creation order (a hover that ends runs before one that starts).
    /// Without a pointer in `window` (not shown, or outside it) only the hovering ones, which
    /// then clear. The walk reads the pointer while another app is active too: each target then
    /// asks its own scope (`computeHovering`).
    func candidates(in window: NSWindow, at event: NSEvent?) -> [PointerHover] {
        var seen = Set<ObjectIdentifier>()
        var ending: [(order: UInt64, target: PointerHover)] = []
        for (id, entry) in hovering {
            guard let target = entry.value else {
                hovering[id] = nil
                continue
            }
            seen.insert(id)
            ending.append((target.order, target))
        }
        var starting: [(order: UInt64, target: PointerHover)] = []
        if let point = PointerHover.pointer(in: window, requireKey: false, event: event, whileInactive: true) {
            for view in Self.views(under: point, in: window) {
                for entry in byView[ObjectIdentifier(view)] ?? [] {
                    guard let target = entry.value, target.hoverView === view, seen.insert(ObjectIdentifier(target)).inserted else { continue }
                    starting.append((target.order, target))
                }
            }
        }
        ending.sort { $0.order < $1.order }
        starting.sort { $0.order < $1.order }
        return ending.map(\.target) + starting.map(\.target)
    }

    /// The shown views of `window` that contain `point` (window coordinates), from the window's
    /// root view down. Every subview whose frame contains the point is entered, overlapping
    /// siblings too (each target hovers by its own rect, also under a sibling). A hidden view and
    /// its subviews are skipped (they cannot hover), and so is a view outside its superview's
    /// bounds there (its visible rect, and AppKit's own hit test, leave it out).
    static func views(under point: NSPoint, in window: NSWindow) -> [NSView] {
        guard var root = window.contentView else { return [] }
        while let up = root.superview { root = up }
        let start = root.convert(point, from: nil)
        guard !root.isHidden, root.bounds.contains(start) else { return [] }
        var found: [NSView] = []
        var stack: [(view: NSView, point: NSPoint)] = [(root, start)]
        while let next = stack.popLast() {
            found.append(next.view)
            for sub in next.view.subviews where !sub.isHidden && sub.frame.contains(next.point) {
                stack.append((sub, sub.convert(next.point, from: next.view)))
            }
        }
        return found
    }

    /// Drops the entries of freed targets.
    private func sweep() {
        for (key, entries) in byView {
            let live = entries.filter { $0.value != nil }
            if live.count != entries.count { byView[key] = live.isEmpty ? nil : live }
        }
        sweepAt = max(256, byView.count * 2)
    }
}
