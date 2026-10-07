import AppKit
import CmuxNextDesign
import QuartzCore

/// Docked columns in the view (dock-column.md, V1 to V4): docked panes
/// and dividers sit at fixed frames above the strip, strip content shifts by
/// the strip origin minus the scroll, docked columns clip the strip, and
/// overlay columns float on a glass backdrop.
extension ScreenContentView {
    /// View x minus strip x at the presented scroll.
    var stripShift: CGFloat { geometry.viewShift(offset: scroll.value) }

    /// The part of the view where strip content shows (local coordinates).
    var uncoveredRect: CGRect {
        guard !geometry.dock.isEmpty else { return bounds }
        return CGRect(x: geometry.uncoveredMinX, y: geometry.uncoveredMinY,
                      width: max(0, geometry.uncoveredMaxX - geometry.uncoveredMinX),
                      height: max(0, geometry.uncoveredMaxY - geometry.uncoveredMinY))
    }

    /// What docked columns hide of the strip (local coordinates): strip
    /// rings and highlights are clipped out of these.
    var coverRects: [CGRect] { geometry.dock.map(\.cover) }

    /// True when the scroll moves this divider or column edge.
    func scrolls(_ kind: DividerHandleView.Kind) -> Bool {
        switch kind {
        case let .split(id): !geometry.fixedSplits.contains(id)
        case let .columnEdge(id), let .rowEdge(id, _): !geometry.dock.contains { $0.column == id }
        }
    }

    /// A geometry rect for `pane` in local coordinates.
    func displayedRect(_ rect: CGRect, pane: PaneID) -> CGRect {
        rect.offsetBy(dx: geometry.scrolls(pane: pane) ? stripShift : 0, dy: -rowOffset(of: pane))
    }

    /// True when `host` belongs to the scrolling strip.
    func isStripHost(_ host: PaneHostView) -> Bool { geometry.scrolls(pane: host.pane) }

    /// Strip panes that slide under a docked column are clipped (V1): a
    /// layer mask keeps the part of the host inside the strip's clip range,
    /// the uncovered range beside a docked column and up to the glass rim's
    /// outer edge beside an overlay (under the rim and the column the strip
    /// stays, so the glass has content to refract).
    func clipToStrip(_ host: PaneHostView, scrolls: Bool, uncovered: CGRect) {
        guard scrolls, !geometry.dock.isEmpty else { return host.setStripClip(nil) }
        let range = CGRect(x: geometry.clipMinX, y: geometry.clipMinY, width: max(0, geometry.clipMaxX - geometry.clipMinX),
                           height: max(0, geometry.clipMaxY - geometry.clipMinY))
        let visible = host.frame.intersection(range)
        if visible == host.frame { return host.setStripClip(nil) }
        host.setStripClip(visible.isNull ? .zero : visible.offsetBy(dx: -host.frame.minX, dy: -host.frame.minY))
    }

    /// Glass backdrops for overlay columns and the stacking order: strip
    /// hosts, strip dividers, backdrops, docked hosts, docked dividers,
    /// then the scrollbar.
    func reconcileDock() {
        let overlays = geometry.dock.filter { $0.dock.mode == .overlay }
        let live = Set(overlays.map(\.column))
        for (column, view) in backdrops where !live.contains(column) {
            view.removeFromSuperview()
            backdrops[column] = nil
        }
        for entry in overlays {
            let view = backdrops[entry.column] ?? {
                let view = DockBackdropView()
                addSubview(view)
                backdrops[entry.column] = view
                return view
            }()
            view.place(cover: entry.glass, column: entry.frame, paneCornerRadius: context.style.paneCornerRadius)
        }
        ensureStacking()
    }

    /// Strip hosts and dividers, then the docks that do not own the corners
    /// (backdrop, hosts, dividers), then the docks that do, then the scrollbar
    /// (layout-model.md F4: column-major side docks draw above bands,
    /// row-major bands above side docks).
    private func rank(_ view: NSView) -> Int {
        switch view {
        case let host as PaneHostView:
            return geometry.scrolls(pane: host.pane) ? 0 : 3 + cornerRank(geometry.dockFrame(containing: host.pane))
        case let divider as DividerHandleView:
            guard !scrolls(divider.kind) else { return 1 }
            if case let .columnEdge(id) = divider.kind { return 4 + cornerRank(geometry.dock.first { $0.column == id }) }
            return 4 + cornerRank(dock(containing: divider.frame))
        case let backdrop as DockBackdropView:
            return 2 + cornerRank(backdrops.first { $0.value === backdrop }.flatMap { entry in geometry.dock.first { $0.column == entry.key } })
        case is StripScrollbarView: return 9
        default: return 0
        }
    }

    /// 3 for a dock that owns the frame's corners, else 0.
    private func cornerRank(_ entry: DockColumnFrame?) -> Int {
        guard let entry else { return 0 }
        return DockStripGeometry.ownsCorners(entry.dock.edge, orientation: geometry.frameOrientation) ? 3 : 0
    }

    private func dock(containing rect: CGRect) -> DockColumnFrame? {
        geometry.dock.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }

    /// Reorders subviews only when the order is wrong. `sortSubviews`
    /// keeps every view in the window (no detach), so terminal surfaces and
    /// page windows are not torn down.
    private func ensureStacking() {
        let ranks = subviews.enumerated().map { rank($1) * 100_000 + $0 }
        guard ranks != ranks.sorted() else { return }
        let table = StackingTable(ranks: Dictionary(uniqueKeysWithValues: zip(subviews.map(ObjectIdentifier.init), ranks)))
        withExtendedLifetime(table) {
            sortSubviews(compareStacking, context: Unmanaged.passUnretained(table).toOpaque())
        }
    }

    /// Clicks inside what a docked column covers go to the docked column
    /// (its panes, dividers, handle) or to this view, never to a strip pane
    /// hidden under it: a layer mask does not change hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, geometry.dock.contains(where: { $0.cover.contains(local) }) else { return super.hitTest(point) }
        for view in subviews.reversed() where !view.isHidden {
            if let host = view as? PaneHostView, geometry.scrolls(pane: host.pane) { continue }
            if let divider = view as? DividerHandleView, scrolls(divider.kind) { continue }
            if let hit = view.hitTest(local) { return hit }
        }
        return self
    }

    /// Pane frames for directional focus in one logical line: the left
    /// docked column before the strip, the strip in its own space, the right
    /// docked column after the strip's end, so every strip column stays
    /// reachable and nothing ties with a docked column by screen position.
    /// Top and bottom docks keep their height and stretch across the strip.
    var navigationFrames: [PaneID: CGRect] {
        let gap = context.style.stripGap
        var result: [PaneID: CGRect] = [:]
        for (pane, rect) in geometry.panes {
            guard let entry = geometry.dockFrame(containing: pane) else {
                result[pane] = rect
                continue
            }
            switch entry.dock.edge {
            case .left: result[pane] = rect.offsetBy(dx: -entry.frame.maxX - gap, dy: 0)
            case .right: result[pane] = rect.offsetBy(dx: geometry.contentWidth + gap - entry.frame.minX, dy: 0)
            case .top, .bottom:
                // A band spans the whole strip in navigation space, so up or
                // down from any strip column reaches it (layout-model.md K1).
                let share = entry.frame.width > 0 ? (rect.minX - entry.frame.minX) / entry.frame.width : 0
                let width = entry.frame.width > 0 ? rect.width / entry.frame.width * geometry.contentWidth : geometry.contentWidth
                result[pane] = CGRect(x: share * geometry.contentWidth, y: rect.minY, width: width, height: rect.height)
            }
        }
        return result
    }
}

/// Sort keys for `ensureStacking`, passed through `sortSubviews`' context.
private nonisolated final class StackingTable: Sendable {
    let ranks: [ObjectIdentifier: Int]
    init(ranks: [ObjectIdentifier: Int]) { self.ranks = ranks }
}

/// `sortSubviews` comparator: reads only the table's immutable ranks.
private nonisolated func compareStacking(_ a: NSView, _ b: NSView, _ context: UnsafeMutableRawPointer?) -> ComparisonResult {
    guard let context else { return .orderedSame }
    let table = Unmanaged<StackingTable>.fromOpaque(context).takeUnretainedValue()
    let x = table.ranks[ObjectIdentifier(a)] ?? 0
    let y = table.ranks[ObjectIdentifier(b)] ?? 0
    return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
}
