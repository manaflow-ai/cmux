import AppKit

/// Where Bonsplit's panes and split views sit, in the content root's
/// coordinates, for one layout (docked or hidden).
///
/// Bonsplit keeps split ratios, so the hidden layout's panes are wider in
/// proportion and every pane edge but the leading one rests elsewhere than
/// the docked edge shifted by the sidebar width.
@MainActor
struct SidebarSlidePaneLayout {
    struct Split {
        let rect: NSRect
        let first: NSRect
        let second: NSRect
        let isVertical: Bool
        let thickness: CGFloat
    }

    private(set) var panes: [ObjectIdentifier: NSRect] = [:]
    private(set) var splits: [ObjectIdentifier: Split] = [:]
    /// Each side of each split (a Bonsplit slot), which carries everything
    /// drawn inside it.
    private(set) var slots: [ObjectIdentifier: NSRect] = [:]
    private var views: [ObjectIdentifier: WeakView] = [:]

    private struct WeakView {
        weak var view: NSView?
    }

    func view(_ id: ObjectIdentifier) -> NSView? { views[id]?.view }

    /// The pane a view (a portal anchor) sits in.
    func pane(containing view: NSView) -> ObjectIdentifier? {
        sequence(first: view, next: { $0.superview }).lazy.map(ObjectIdentifier.init).first { panes[$0] != nil }
    }

    var isEmpty: Bool { panes.isEmpty }

    static func measure(in reference: NSView) -> Self {
        var layout = Self()
        func rect(_ view: NSView) -> NSRect { reference.convert(view.bounds, from: view) }

        func walk(_ view: NSView) {
            // Hidden workspaces stay mounted at zero opacity.
            guard !view.isHidden, view.alphaValue > 0, (view.layer?.opacity ?? 1) > 0 else { return }
            let id = ObjectIdentifier(view)
            if SidebarSlideTabRowCapture.isSplitSlot(view) {
                layout.slots[id] = rect(view)
                layout.views[id] = WeakView(view: view)
            }
            if let split = splitView(view) {
                let slots = split.arrangedSubviews
                layout.splits[id] = Split(
                    rect: rect(split),
                    first: rect(slots[0]),
                    second: rect(slots[1]),
                    isVertical: split.isVertical,
                    thickness: max(split.dividerThickness, 1)
                )
                layout.views[id] = WeakView(view: split)
            } else if isLeaf(view) {
                layout.panes[id] = rect(view)
                layout.views[id] = WeakView(view: view)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(reference)
        return layout
    }

    /// A Bonsplit split view: two sides, each a split slot.
    static func splitView(_ view: NSView) -> NSSplitView? {
        guard let split = view as? NSSplitView, split.arrangedSubviews.count == 2,
              split.arrangedSubviews.allSatisfy(SidebarSlideTabRowCapture.isSplitSlot) else { return nil }
        return split
    }

    /// A pane's own hosting view: in a split slot, or a lone pane, and not
    /// itself holding a further split.
    private static func isLeaf(_ view: NSView) -> Bool {
        let inSlot = view.superview.map(SidebarSlideTabRowCapture.isSplitSlot) == true
        guard inSlot || NSStringFromClass(type(of: view)).contains("PaneContainerView") else { return false }
        func holdsSplit(_ view: NSView) -> Bool {
            view.subviews.contains { splitView($0) != nil || holdsSplit($0) }
        }
        return !holdsSplit(view)
    }

    /// The same panes, rect for rect, within half a point.
    func matches(_ other: Self) -> Bool {
        func close(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.height - b.height) < 0.5
        }
        guard panes.count == other.panes.count, splits.count == other.splits.count else { return false }
        return panes.allSatisfy { id, rect in other.panes[id].map { close($0, rect) } == true }
    }

    /// The docked layout predicted from this (hidden) one by Bonsplit's
    /// rule: the root loses the sidebar width at its leading edge, and each
    /// vertical split puts its divider at the pixel-rounded fraction of its
    /// available width. Used when no docked layout was seen for this one.
    func predictedDocked(in reference: NSView, sidebarWidth: CGFloat) -> Self {
        var docked = Self()
        docked.views = views
        let scale = reference.window?.backingScaleFactor ?? 2
        func rect(_ view: NSView) -> NSRect { reference.convert(view.bounds, from: view) }
        func assign(_ view: NSView, hiddenSlot: NSRect, dockedSlot: NSRect) {
            let id = ObjectIdentifier(view)
            let own = rect(view)
            let mapped = NSRect(
                x: own.minX - hiddenSlot.minX + dockedSlot.minX,
                y: own.minY,
                width: own.width - (hiddenSlot.width - dockedSlot.width),
                height: own.height
            )
            if panes[id] != nil {
                docked.panes[id] = mapped
                return
            }
            if slots[id] != nil {
                docked.slots[id] = mapped
            }
            if let split = splits[id], let splitView = Self.splitView(view) {
                var first = NSRect(x: mapped.minX, y: split.first.minY, width: mapped.width, height: split.first.height)
                var second = NSRect(x: mapped.minX, y: split.second.minY, width: mapped.width, height: split.second.height)
                if split.isVertical {
                    let available = split.rect.width - split.thickness
                    let fraction = available > 0 ? split.first.width / available : 0.5
                    let position = ((mapped.width - split.thickness) * fraction * scale).rounded() / scale
                    first.size.width = position
                    second.origin.x = mapped.minX + position + split.thickness
                    second.size.width = max(0, mapped.maxX - second.minX)
                }
                docked.splits[id] = Split(rect: mapped, first: first, second: second, isVertical: split.isVertical, thickness: split.thickness)
                let slots = splitView.arrangedSubviews
                assign(slots[0], hiddenSlot: rect(slots[0]), dockedSlot: first)
                assign(slots[1], hiddenSlot: rect(slots[1]), dockedSlot: second)
                return
            }
            for subview in view.subviews where !subview.isHidden {
                assign(subview, hiddenSlot: own, dockedSlot: mapped)
            }
        }
        func roots(_ view: NSView) {
            guard !view.isHidden else { return }
            let id = ObjectIdentifier(view)
            if panes[id] != nil || splits[id] != nil {
                let own = rect(view)
                assign(view, hiddenSlot: own, dockedSlot: NSRect(x: own.minX + sidebarWidth, y: own.minY, width: own.width - sidebarWidth, height: own.height))
                return
            }
            view.subviews.forEach(roots)
        }
        roots(reference)
        return docked
    }
}
