import AppKit

/// `PointerHover`'s targets filed by view, and the ones that hover now. A refresh walks the
/// window's view tree down along the pointer, so it reads only the targets whose views contain the
/// pointer, plus the hovering ones (a handful). No window is stored: a view that moves to another
/// window is found there by that window's next refresh, and a hovering one clears on any refresh.
///
/// The walk's cost is the children of the views on the pointer's path (it reads each child's
/// `isHidden` and `frame` to pick the ones to enter), not the views on the path alone: a flat
/// container with every item as a direct subview (an unvirtualized list, a long tab strip) costs
/// its item count per refresh, in cheap getters and with no target recomputed. Nested layouts
/// cost their fan-out per level.
@MainActor
final class TargetIndex {
    private struct Weak {
        weak var value: PointerHover?
    }

    private struct Entry {
        /// Checked on lookup: a freed view's identifier can be reused by a new view.
        weak var view: NSView?
        var targets: [Weak]
    }

    private var byView: [ObjectIdentifier: Entry] = [:]
    /// Targets that hover now.
    private var hovering: [ObjectIdentifier: Weak] = [:]
    private var nextOrder: UInt64 = 0

    /// Files `target` under `view` and returns its creation order (a refresh runs its targets in it).
    func insert(_ target: PointerHover, view: NSView) -> UInt64 {
        nextOrder &+= 1
        let key = ObjectIdentifier(view)
        if byView[key]?.view !== view { byView[key] = Entry(view: view, targets: []) }
        byView[key]?.targets.append(Weak(value: target))
        return nextOrder
    }

    func noteHovering(_ target: PointerHover, _ hovers: Bool) {
        hovering[ObjectIdentifier(target)] = hovers ? Weak(value: target) : nil
    }

    /// Drops freed targets filed under `key` (a target's `deinit`).
    func dropFreed(under key: ObjectIdentifier) {
        guard var entry = byView[key] else { return }
        entry.targets.removeAll { $0.value == nil }
        byView[key] = entry.targets.isEmpty || entry.view == nil ? nil : entry
    }

    /// The targets a refresh of `window` reads: those whose views lie under `point` (window
    /// coordinates; nil: no pointer in the window) and those that hover now, in creation order
    /// with the hovering ones first (a hover that ends runs before one that starts).
    ///
    /// The walk enters a view only when it is shown and the point is inside its frame and its
    /// bounds, as `NSView.hitTest(_:)` does on every macOS major whatever `clipsToBounds` says:
    /// a target hovers only where its clicks land, so a part of a view that overflows its
    /// superview (`masksToBounds = false`) shows no hover there, as it takes no click there.
    /// Overlapping siblings are both entered.
    func candidates(in window: NSWindow, at point: NSPoint?) -> [PointerHover] {
        var found: [ObjectIdentifier: PointerHover] = [:]
        for (id, entry) in hovering {
            if let target = entry.value { found[id] = target } else { hovering[id] = nil }
        }
        if let point, var root = window.contentView {
            while let parent = root.superview { root = parent }
            var stack: [(view: NSView, local: NSPoint)] = []
            let local = root.convert(point, from: nil)
            if !root.isHidden, root.bounds.contains(local) { stack.append((root, local)) }
            while let step = stack.popLast() {
                collect(step.view, into: &found)
                for child in step.view.subviews where !child.isHidden {
                    // A rotated child's frame is its bounding box: test it in its own coordinates.
                    guard child.frameRotation != 0 || child.frame.contains(step.local) else { continue }
                    let inner = child.convert(step.local, from: step.view)
                    if child.bounds.contains(inner) { stack.append((child, inner)) }
                }
            }
        }
        // One integer per target: a tuple compare goes through the runtime's tuple metadata on
        // every comparison.
        return found.values.map { (key: ($0.isHovering ? 0 : 1 << 63) | $0.order, target: $0) }
            .sorted { $0.key < $1.key }.map(\.target)
    }

    private func collect(_ view: NSView, into found: inout [ObjectIdentifier: PointerHover]) {
        let key = ObjectIdentifier(view)
        guard let entry = byView[key] else { return }
        guard entry.view === view else {
            // A freed view's identifier, reused by a view without targets.
            if entry.view == nil { byView[key] = nil }
            return
        }
        for ref in entry.targets {
            if let target = ref.value { found[ObjectIdentifier(target)] = target }
        }
    }
}
