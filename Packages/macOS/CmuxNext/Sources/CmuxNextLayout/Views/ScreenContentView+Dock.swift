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

    /// What docked columns hide of the strip (local coordinates; a dock growing in, up to its moving
    /// edge): strip rings and highlights are clipped out of these.
    var coverRects: [CGRect] { PaneArrival.covers(geometry, docks: growingDocks) }

    /// For each shown pane host, the frames of shown panes stacked above it
    /// that overlap it (local coordinates), from one walk of the subviews
    /// front to back. Overlaps happen only mid-motion (an unzoom's pane
    /// springing back over the panes it uncovers, a zoom's growing over the
    /// others) and under docked columns; their headers are see-through, so
    /// what is under them is masked out. Computed once per presentation
    /// pass, not once per host (which walked every subview per host).
    func panesAbove() -> [ObjectIdentifier: [CGRect]] {
        var covers: [ObjectIdentifier: [CGRect]] = [:]
        var front: [CGRect] = []
        for case let host as PaneHostView in subviews.reversed() {
            let overlapping = front.filter { $0.intersection(host.frame).width > 0.5 && $0.intersection(host.frame).height > 0.5 }
            if !overlapping.isEmpty { covers[ObjectIdentifier(host)] = overlapping.reversed() }
            guard !host.isHidden && host.alphaValue > 0.99 else { continue }
            front.append(host.frame)
        }
        return covers
    }

    /// What hides `host`'s ring and dim (local coordinates): the docked columns over a strip pane,
    /// and the panes in front of it (`above`, from `panesAbove()`).
    /// The zooming pane is above the docks (`rank`): they hide none of it.
    func ringCovers(of host: PaneHostView, docks: [CGRect], above: [ObjectIdentifier: [CGRect]]) -> [CGRect] {
        (isStripHost(host) && host.pane != zoomMotion.pane ? docks : []) + (above[ObjectIdentifier(host)] ?? [])
    }

    /// True when the scroll moves this divider or column edge.
    func scrolls(_ kind: DividerHandleView.Kind) -> Bool {
        switch kind {
        case let .split(id): !geometry.fixedSplits.contains(id)
        case let .columnEdge(id), let .rowEdge(id, _): !geometry.dock.contains { $0.column == id }
        }
    }

    /// A geometry rect for `pane` in local coordinates.
    func displayedRect(_ rect: CGRect, pane: PaneID) -> CGRect {
        rect.offsetBy(dx: (geometry.scrolls(pane: pane) ? stripShift : 0) - areaOffset(of: pane), dy: -rowOffset(of: pane))
    }

    /// True when `host` belongs to the scrolling strip.
    func isStripHost(_ host: PaneHostView) -> Bool { geometry.scrolls(pane: host.pane) }

    /// Strip panes that slide under a docked column are clipped (V1): a
    /// layer mask keeps the part of the host inside the strip's clip range,
    /// the uncovered range beside a docked column and up to the glass rim's
    /// outer edge beside an overlay (under the rim and the column the strip
    /// stays, so the glass has content to refract).
    /// `clip` is that range (`PaneArrival.stripClip`, which follows a dock
    /// growing in).
    /// Any part under a pane in front (`above`, from `panesAbove()`) is cut off too: a pane over one
    /// whole side narrows the clip; one over a corner or the middle (a zoom growing over a grid) is a
    /// cutout the mask leaves out (the pane in front has transparent padding) and a Chromium page
    /// reads (its child window draws above every view).
    /// Returns true when the host's clip changed. A host whose frame, clip range, area window and
    /// covers are what they were last time keeps its clip without recomputing it (`force` recomputes).
    @discardableResult
    func clipToStrip(_ host: PaneHostView, scrolls: Bool, clip: CGRect?, above: [ObjectIdentifier: [CGRect]], force: Bool = false) -> Bool {
        // A pane scrolled partly out of its scroll area shows only inside the area's window.
        let areaWindow = displayedAreaWindow(of: host.pane)
        let input = StripClipInput(frame: host.frame, clip: scrolls ? clip : nil, areaWindow: areaWindow,
                                   covers: above[ObjectIdentifier(host)] ?? [])
        guard force || host.stripClipInput != input else { return false }
        host.stripClipInput = input
        stripClipsComputed += 1
        // Everything below is in the host's own coordinates: the input's clip, area window and covers
        // are already local and cut to the host's bounds (a screen-space rect met with a local one
        // cut a right pane's mask to its width minus its x, Leo 2026-10-24).
        let bounds = CGRect(origin: .zero, size: input.size)
        var visible = bounds
        if let clip = input.clip { visible = visible.intersection(clip) }
        if let areaWindow = input.areaWindow { visible = visible.intersection(areaWindow) }
        host.areaHitClip = input.areaWindow
        var cutouts: [CGRect] = []
        for cover in input.covers {
            let rest = visible.remainder(outside: cover), shared = visible.intersection(cover)
            if rest == visible, !shared.isNull, shared.width > 0.5, shared.height > 0.5 {
                cutouts.append(shared)
            } else {
                visible = rest
            }
        }
        let changed = visible == bounds && cutouts.isEmpty
            ? host.setStripClip(nil)
            : host.setStripClip(visible.isNull ? .zero : visible, cutouts: cutouts)
        // A clip can change while the pane stays put (a dock growing over it): the window's
        // Chromium pages re-read their clip shapes, which carry this mask.
        if changed { context.stripClipsDidChange() }
        return changed
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
    /// row-major bands above side docks). A zooming or unzooming pane is above
    /// all of them until it lands (DESIGN Z2, Z4).
    private func rank(_ view: NSView) -> Int {
        switch view {
        case let host as PaneHostView:
            if host.pane == zoomMotion.pane { return 10 }
            // A zoom's covered panes stay under every pane.
            if covered.contains(host.pane) { return -1 }
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
    func ensureStacking() {
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
        guard !isHidden, geometry.dock.contains(where: { $0.cover.contains(local) }) else {
            // A zoom's covered panes have left the layout: a click there goes to this view.
            let hit = super.hitTest(point)
            guard !covered.isEmpty, let hit, coveredHost(containing: hit) != nil else { return hit }
            return self
        }
        for view in subviews.reversed() where !view.isHidden {
            if let host = view as? PaneHostView, geometry.scrolls(pane: host.pane) || covered.contains(host.pane) { continue }
            if let divider = view as? DividerHandleView, scrolls(divider.kind) { continue }
            if let hit = view.hitTest(local) { return hit }
        }
        return self
    }

    private func coveredHost(containing view: NSView) -> PaneHostView? {
        var current: NSView? = view
        while let candidate = current, candidate !== self {
            if let host = candidate as? PaneHostView, covered.contains(host.pane) { return host }
            current = candidate.superview
        }
        return nil
    }

    /// Pane frames for directional focus in one logical line: the left
    /// docked column before the strip, the strip in its own space, the right
    /// docked column after the strip's end, so every strip column stays
    /// reachable and nothing ties with a docked column by screen position.
    /// Top and bottom docks keep their height and stretch across the strip.
    var navigationFrames: [PaneID: CGRect] {
        let gap = context.style.stripGap
        var result: [PaneID: CGRect] = [:]
        for (pane, shown) in geometry.panes {
            // In a scroll area: x mapped into the area's window, whatever its offset (K1); y as
            // shown (a row's vertical offset applies).
            let mapped = baseGeometry.scrollAreaOfPane[pane] == nil ? nil : baseGeometry.navigationRect(of: pane)
            let rect = mapped.map { CGRect(x: $0.minX, y: shown.minY, width: $0.width, height: shown.height) } ?? shown
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
nonisolated final class StackingTable: Sendable {
    let ranks: [ObjectIdentifier: Int]
    init(ranks: [ObjectIdentifier: Int]) { self.ranks = ranks }
}

/// `sortSubviews` comparator: reads only the table's immutable ranks.
nonisolated func compareStacking(_ a: NSView, _ b: NSView, _ context: UnsafeMutableRawPointer?) -> ComparisonResult {
    guard let context else { return .orderedSame }
    let table = Unmanaged<StackingTable>.fromOpaque(context).takeUnretainedValue()
    let x = table.ranks[ObjectIdentifier(a)] ?? 0
    let y = table.ranks[ObjectIdentifier(b)] ?? 0
    return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
}

extension CGRect {
    /// What is left outside `cover` when that is one rect (`cover` spans this rect's full height or
    /// width from one side, as a pane springing over its neighbors does); else this rect.
    func remainder(outside cover: CGRect) -> CGRect {
        let shared = intersection(cover)
        guard !shared.isNull, shared.width > 0.5, shared.height > 0.5 else { return self }
        if shared.height >= height - 0.5 {
            if shared.minX <= minX + 0.5 { return CGRect(x: shared.maxX, y: minY, width: maxX - shared.maxX, height: height) }
            if shared.maxX >= maxX - 0.5 { return CGRect(x: minX, y: minY, width: shared.minX - minX, height: height) }
        }
        if shared.width >= width - 0.5 {
            if shared.minY <= minY + 0.5 { return CGRect(x: minX, y: shared.maxY, width: width, height: maxY - shared.maxY) }
            if shared.maxY >= maxY - 0.5 { return CGRect(x: minX, y: minY, width: width, height: shared.minY - minY) }
        }
        return self
    }
}
