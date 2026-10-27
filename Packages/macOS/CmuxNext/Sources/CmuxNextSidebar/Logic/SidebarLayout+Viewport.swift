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
    /// spring on the document view's layer carries what is on screen from where it shows to it on the render
    /// server, as Chrome's compositor runs a programmatic smooth scroll (cc/animation/scroll_offset_animation_curve.cc)
    /// with no main-thread scroll per frame. What shows stays within `reach` of the destination: pass the overscan
    /// the list realizes around its clip, so a long jump or a retarget never shows rows it has not realized. Not
    /// animated, the content lands at once. `moved` runs once, after the origin changed.
    func scrollContent(toY y: CGFloat, animated: Bool, reach: CGFloat, moved: @escaping @MainActor () -> Void) {
        let clip = contentView
        let origin = NSPoint(x: clip.bounds.minX, y: y)
        let before = contentGeometry()
        let residual = contentSpringResidual()
        clip.setBoundsOrigin(origin)
        reflectScrolledClipView(clip)
        if let before, let after = contentGeometry() {
            springContent(by: CGPoint(x: residual.x + after.clip.x - before.clip.x - (after.document.x - before.document.x),
                                      y: residual.y + after.clip.y - before.clip.y - (after.document.y - before.document.y)),
                          reach: animated ? reach : 0)
        }
        moved()
    }

    /// A person's scroll takes over from a programmatic one where it shows (Chrome's LayerTreeHostImpl::ScrollBegin
    /// aborts the impl-side scroll animation at its current offset): the clip's origin moves to what the spring
    /// showed and the spring comes off, so nothing on screen moves.
    func stopContentSpring() {
        guard let layer = documentView?.layer, layer.animation(forKey: Self.scrollSpringKey) != nil else { return }
        let residual = contentSpringResidual()
        layer.removeAnimation(forKey: Self.scrollSpringKey)
        guard residual != .zero else { return }
        // The document shows at its position minus the clip's origin: the origin takes the spring's offset off.
        let clip = contentView
        let shown = NSRect(origin: NSPoint(x: clip.bounds.minX - residual.x, y: clip.bounds.minY - residual.y), size: clip.bounds.size)
        clip.setBoundsOrigin(clip.constrainBoundsRect(shown).origin)
        reflectScrolledClipView(clip)
    }

    /// The clip layer's bounds origin and the document layer's position, both in the clip layer's coordinates:
    /// the two places a scroll can move the content, read as the layers have them, whatever the views' flips.
    /// Nil unless the document layer sits right in the clip's.
    private func contentGeometry() -> (clip: CGPoint, document: CGPoint)? {
        guard let clipLayer = contentView.layer, let layer = documentView?.layer, layer.superlayer === clipLayer else { return nil }
        return (clipLayer.bounds.origin, layer.position)
    }

    /// How far the running scroll spring shows the document from its model position now, in the clip layer's
    /// coordinates; zero with no spring. Solved from the spring's start and its `.move` tuning (Chrome's compositor
    /// reads a scroll curve's value at a time, cc/animation/scroll_offset_animation_curve.cc `GetValue`), so a spring
    /// added in this turn, which no presentation layer shows yet, counts from its start.
    private func contentSpringResidual() -> CGPoint {
        guard let layer = documentView?.layer, let spring = layer.animation(forKey: Self.scrollSpringKey),
              let from = ((spring as? CABasicAnimation)?.fromValue as? NSValue)?.pointValue else { return .zero }
        let elapsed = layer.convertTime(CACurrentMediaTime(), from: nil) - spring.beginTime
        let left = CGFloat(SpringValue.solve(displacement: 1, velocity: 0, time: elapsed, parameters: Motion.sidebar.spring(.move)).displacement)
        return CGPoint(x: from.x * left, y: from.y * left)
    }

    /// Shows the content `offset` from its model position and springs it home: one spring, in place of any running
    /// one, from the whole offset clamped to `reach`. What shows moves at once only by the part past `reach`.
    private func springContent(by offset: CGPoint, reach: CGFloat) {
        guard let layer = documentView?.layer else { return }
        let clamp = { (value: CGFloat) in min(max(value, -reach), reach) }
        let start = CGPoint(x: clamp(offset.x), y: clamp(offset.y))
        guard start != .zero, window != nil, Motion.sidebar.animatesMovement, Motion.canAnimate(in: contentView) else {
            layer.removeAnimation(forKey: Self.scrollSpringKey)
            return
        }
        let spring = Motion.sidebar.springAnimation(.move, "position", from: NSValue(point: start), to: NSValue(point: .zero))
        spring.isAdditive = true
        spring.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.add(spring, forKey: Self.scrollSpringKey)
    }

    /// The key of the spring `scrollContent(toY:animated:reach:moved:)` adds to the document view's layer.
    static let scrollSpringKey = "cmux.scroll"
}
