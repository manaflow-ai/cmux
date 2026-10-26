import AppKit
import CmuxNextDesign
import QuartzCore

extension SidebarLayout {
    /// Space kept around a revealed active row (close-focus.md).
    static let revealPadding: CGFloat = 8

    /// The rows as `ListViewport` sees them in a viewport `height` tall.
    func viewport(height: CGFloat) -> ListViewport<SidebarRowKey> {
        ListViewport(items: rows.map { .init(id: $0.key, start: $0.y, length: $0.height) },
                     viewport: height, content: max(totalHeight, height))
    }

    /// The extent a reveal of the selection shows (u2605: "Command-1 doesn't scroll all the way up"):
    /// `span` (row `key`, or an item inside block row `key`) with its context: the header rows right
    /// above it (section, group, folder) and the block's own top, the list's top (0) when no workspace
    /// stop draws above it (only top items or headers), and the list's end when nothing lies below it.
    /// Context that would not fit in a viewport `height` tall (with `revealPadding` on both sides) is
    /// dropped, the end first, so the span itself always shows. `id` is the selection's identity
    /// (`SidebarListViewComponents.selectionReveal`). Nil when the layout does not show `key`.
    func revealExtent(id: SidebarRowKey, row key: SidebarRowKey, span: (start: CGFloat, length: CGFloat)? = nil,
                      height: CGFloat) -> ListViewport<SidebarRowKey>.Item? {
        guard let row = row(for: key) else { return nil }
        // O(log n): `row(for:)` found it, rows are sorted by y; equal tops (empty rows) fall back to a scan.
        guard let index = lastIndex(startingAtOrBefore: row.y).flatMap({ rows[$0].key == key ? $0 : nil })
            ?? rows.firstIndex(where: { $0.key == key }) else { return nil }
        let start = span?.start ?? row.y, end = start + (span?.length ?? row.height)
        var lead = row.key.isBlock ? row.y : start
        var above = index - 1
        while above >= 0, rows[above].key.isRevealHeader { lead = rows[above].y; above -= 1 }
        // Only top items (blocks, link rows) or headers above: the list's top padding, its top items and any
        // header belong to the first stop (`SidebarItemOrder.revealsTop`: Cmd-1 to Home or the first workspace).
        if !rows[..<index].contains(where: \.isWorkspaceStop) { lead = 0 }
        let trail = rows[(index + 1)...].contains(where: { $0.key.isRevealStop }) ? end : max(totalHeight, end)
        let fits = { (lead: CGFloat, trail: CGFloat) in trail - lead + Self.revealPadding * 2 <= height }
        let (l, t) = fits(lead, trail) ? (lead, trail) : fits(lead, end) ? (lead, end) : (start, end)
        return .init(id: id, start: l, length: t - l)
    }
}

private extension SidebarRow {
    /// A workspace stop (a workspace row, or a collapsed group, one stop): what
    /// `SidebarItemOrder.revealsTop` counts before a selection (top items do not).
    var isWorkspaceStop: Bool {
        switch key {
        case .workspace, .tab: true
        case .group: isCollapsed
        default: false
        }
    }
}

private extension SidebarRowKey {
    /// A row that only titles the rows below it.
    var isRevealHeader: Bool {
        switch self {
        case .section, .group, .folder, .status: true
        default: false
        }
    }

    /// A row the selection can stand on (a block holds selectable items).
    var isRevealStop: Bool {
        switch self {
        case .workspace, .item, .tab, .block: true
        default: false
        }
    }

    var isBlock: Bool { if case .block = self { true } else { false } }
}

extension NSScrollView {
    /// Moves the content to `y` in this turn: the clip's origin is set once, so hit tests, the scroller and the
    /// rows the list realizes read the destination now. Animated (and with movement on), an additive `.move`
    /// spring on the document view's layer carries what is on screen from the old origin to it on the render
    /// server, as Chrome's compositor runs a programmatic smooth scroll (cc/animation/scroll_offset_animation_curve.cc)
    /// with no main-thread scroll per frame. The spring starts at most `SidebarStyle.overscan` away, inside the rows
    /// the list keeps realized around the destination, so a long jump never shows rows it has not realized. `moved`
    /// runs once, after the origin changed.
    func scrollContent(toY y: CGFloat, animated: Bool, moved: @escaping @MainActor () -> Void) {
        let clip = contentView
        let origin = NSPoint(x: clip.bounds.minX, y: y)
        let before = contentGeometry()
        clip.setBoundsOrigin(origin)
        reflectScrolledClipView(clip)
        if animated, let before, let after = contentGeometry() { springContent(from: before, to: after) }
        moved()
    }

    /// A person's scroll takes over from a programmatic one (Chrome's LayerTreeHostImpl::ScrollBegin aborts the
    /// impl-side scroll animation): the content shows the clip's origin now.
    func stopContentSpring() {
        guard let layer = documentView?.layer else { return }
        for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.scrollSpringKey) { layer.removeAnimation(forKey: key) }
    }

    /// The clip layer's bounds origin and the document layer's position, both in the clip layer's coordinates:
    /// the two places a scroll can move the content, read as the layers have them, whatever the views' flips.
    /// Nil unless the document layer sits right in the clip's.
    private func contentGeometry() -> (clip: CGPoint, document: CGPoint)? {
        guard let clipLayer = contentView.layer, let layer = documentView?.layer, layer.superlayer === clipLayer else { return nil }
        return (clipLayer.bounds.origin, layer.position)
    }

    /// Holds the content where it showed before the scroll and springs it to where it shows now. A retarget adds
    /// one more spring: the running ones keep their part, so what shows never steps.
    private func springContent(from before: (clip: CGPoint, document: CGPoint), to after: (clip: CGPoint, document: CGPoint)) {
        let reach = SidebarStyle.overscan
        let clamp = { (value: CGFloat) in min(max(value, -reach), reach) }
        let offset = CGPoint(x: clamp(after.clip.x - before.clip.x - (after.document.x - before.document.x)),
                             y: clamp(after.clip.y - before.clip.y - (after.document.y - before.document.y)))
        guard offset != .zero, window != nil, Motion.sidebar.animatesMovement, Motion.canAnimate(in: contentView),
              let layer = documentView?.layer else { return }
        let spring = Motion.sidebar.springAnimation(.move, "position", from: NSValue(point: offset), to: NSValue(point: .zero))
        spring.isAdditive = true
        spring.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        // Past the highest running key, so a retarget adds a spring instead of replacing a running one.
        let prefix = Self.scrollSpringKey + "."
        let running = (layer.animationKeys() ?? []).compactMap { key in key.hasPrefix(prefix) ? Int(key.dropFirst(prefix.count)) : nil }
        layer.add(spring, forKey: prefix + String((running.max() ?? -1) + 1))
    }

    /// The key prefix of the springs `scrollContent(toY:animated:moved:)` adds to the document view's layer.
    static let scrollSpringKey = "cmux.scroll"
}
