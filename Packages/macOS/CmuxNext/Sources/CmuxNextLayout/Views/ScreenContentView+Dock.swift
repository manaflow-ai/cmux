import AppKit
import CmuxNextDesign
import QuartzCore

/// Docked columns in the view (dock-column.md, V1 to V4): docked panes
/// and dividers sit at fixed frames above the strip, strip content shifts by
/// the strip origin minus the scroll, the strip container clips the strip
/// beside docked columns, and overlay columns float on a glass backdrop.
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

    /// This view's subviews back to front, the strip container's hosts in its place and a row's or scroll
    /// area's container's hosts in its own: the order the panes draw in.
    var stackedSubviews: [NSView] {
        subviews.flatMap { $0 === stripContainer ? Self.stacked(in: stripContainer) : [$0] }
    }

    private static func stacked(in container: NSView) -> [NSView] {
        container.subviews.flatMap { $0 is ScrollerPanContainerView ? stacked(in: $0) : [$0] }
    }

    /// True when `host` is placed by this screen (directly, or in its strip container or one of the
    /// containers in it).
    func holds(_ host: PaneHostView) -> Bool { host.superview === self || host.isDescendant(of: stripContainer) }

    /// The part of `host` that shows (this view's coordinates; a host's frame is in them in either
    /// parent): its frame cut by its own mask and the strip container's clip. Null when none shows.
    func shownFrame(_ host: PaneHostView) -> CGRect {
        let shown = host.stripShownRect
        let moved = panTranslation(of: host)
        return shown.isEmpty ? .null : shown.offsetBy(dx: host.frame.minX + moved.dx, dy: host.frame.minY + moved.dy)
    }

    /// For each shown pane host, the parts of shown panes stacked above it
    /// that overlap it (local coordinates), from one walk of the stacked
    /// views front to back. Overlaps happen only mid-motion (an unzoom's pane
    /// springing back over the panes it uncovers, a zoom's growing over the
    /// others) and under docked columns. Read by the overlay sync (rings and
    /// dims), not by the clip: panes in front are above in the layer tree.
    /// A pane in front covers its ``coverFrame(_:)``.
    func panesAbove() -> [ObjectIdentifier: [CGRect]] {
        var covers: [ObjectIdentifier: [CGRect]] = [:]
        var front: [CGRect] = []
        for case let host as PaneHostView in stackedSubviews.reversed() {
            let frame = placedFrame(of: host)
            let overlapping = front.filter { $0.intersection(frame).width > 0.5 && $0.intersection(frame).height > 0.5 }
            if !overlapping.isEmpty { covers[ObjectIdentifier(host)] = overlapping.reversed() }
            guard !host.isHidden && host.alphaValue > 0.99 else { continue }
            let shown = coverFrame(host)
            if !shown.isNull { front.append(shown) }
        }
        return covers
    }

    /// The parts (local coordinates) of the shown panes stacked in front of `host` that overlap it,
    /// back to front: what a Chromium page in `host` drawing in its own window leaves out
    /// (`PaneHostView.pageCovers`, which keeps the answer until `coverVersion` changes).
    func panes(inFrontOf host: PaneHostView) -> [CGRect] {
        let frame = placedFrame(of: host)
        var result: [CGRect] = []
        var inFront = false
        func visit(_ view: NSView) {
            guard let other = view as? PaneHostView else { return }
            if other === host {
                inFront = true
                return
            }
            guard inFront, !other.isHidden, other.alphaValue > 0.99 else { return }
            let shown = coverFrame(other), shared = shown.intersection(frame)
            if !shared.isNull, shared.width > 0.5, shared.height > 0.5 { result.append(shown) }
        }
        stackedSubviews.forEach(visit)
        return result
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

    /// Strip panes that slide under a docked column are clipped (V1) by the strip container's
    /// bounds (`placeStripContainer`): the uncovered range beside a docked column and up to the glass
    /// rim's outer edge beside an overlay (under the rim and the column the strip stays, so the glass
    /// has content to refract). A pane in front (a dock, a zoom growing over a grid) is above in the
    /// layer tree. What is left per host is its scroll area (a pane scrolled partly out of its area
    /// shows only inside the area's window) and, while a zoom lifts the container, the strip's range
    /// it keeps (`heldStripClip`, `fronts` from `liftedFronts`): both through a mask.
    /// Returns true when the host's clip changed. A host whose frame and inputs are what they were
    /// last time keeps its clip without recomputing it (`force` recomputes); a host with neither has
    /// the same input on every frame, and so does one a zoom leaves still under its pane.
    @discardableResult
    func clipToStrip(_ host: PaneHostView, fronts: [CGRect] = [], cover: CGRect? = nil, force: Bool = false) -> Bool {
        // A host in its scroll area's container is clipped by the container (`placeScrollerContainers`).
        let inAreaContainer = (host.superview as? ScrollerPanContainerView)?.scroller.isArea ?? false
        // The zooming pane itself is not cut; every pane under it is, where it shows (``zoomCover``).
        let hole = host.pane == zoomMotion.pane ? nil : cover.map { convert($0, to: host.superview).intersection(host.frame) }
        let input = StripClipInput(frame: host.frame, areaWindow: inAreaContainer ? nil : displayedAreaWindow(of: host.pane),
                                   stripClip: heldStripClip(of: host, fronts: fronts), cover: hole)
        guard force || host.stripClipInput != input else { return false }
        host.stripClipInput = input
        stripClipsComputed += 1
        host.areaHitClip = input.areaWindow
        let bounds = CGRect(origin: .zero, size: input.size)
        var visible = bounds
        if let window = input.areaWindow { visible = visible.intersection(window) }
        if let range = input.stripClip { visible = visible.intersection(range) }
        let clip: CGRect? = visible == bounds ? nil : (visible.isNull ? .zero : visible)
        let changed = host.setStripClip(clip, cover: input.cover)
        // A clip can change while the pane stays put (its area scrolled, a zoom lifted the container):
        // the window's Chromium pages re-read their clip shapes, which carry this mask.
        if changed { context.stripClipsDidChange() }
        return changed
    }

    /// While a zoom lifts the strip container, the part of the strip's range a host that stays under
    /// the zooming pane keeps (this view's coordinates): the range, less the docks' panes and glass
    /// (`fronts`), which the lifted container is above now. Nil when it keeps all of itself, and for
    /// every other host. The hosts a zoom leaves are still, so this is computed when the zoom starts
    /// and when it lands, not per frame.
    func heldStripClip(of host: PaneHostView, fronts: [CGRect]) -> CGRect? {
        // A screen with no docked column: the lifted container's frame is the range, and it clips alike.
        guard stripContainer.isLifted, stripContainer.range != stripContainer.frame,
              host.isDescendant(of: stripContainer), host.pane != zoomMotion.pane else { return nil }
        var visible = stripContainer.range.intersection(host.frame)
        if visible.isNull { return .zero }
        for front in fronts { visible = visible.remainder(outside: front) }
        return visible == host.frame ? nil : visible
    }

    /// What stacks in front of the strip at rest and under the lifted strip container during a zoom:
    /// the frames of the docks' shown panes and of the overlay columns' glass. Empty while not lifted.
    var liftedFronts: [CGRect] {
        guard stripContainer.isLifted else { return [] }
        return subviews.compactMap { view -> CGRect? in
            if let host = view as? PaneHostView { return !host.isHidden && host.alphaValue > 0.99 ? host.frame : nil }
            return view is DockBackdropView ? view.frame : nil
        }
    }

    /// The zooming pane's host sits in the strip container: the container is lifted above the docks
    /// until the zoom lands (`rank`, `placeStripContainer`).
    var liftsStripContainer: Bool {
        guard let pane = zoomMotion.pane, let host = context.hosts[pane] else { return false }
        return host.isDescendant(of: stripContainer)
    }

    /// Where `pane`'s host sits: in the strip container when it scrolls with the strip (in its row's or
    /// scroll area's container there, `ScreenContentView+Scrollers.swift`), else in this view (a dock's
    /// pane, a canvas). A host changes parent only when the pane docks or undocks or the
    /// screen becomes or stops being a canvas; never for a zoom (a zoom acts on the focused pane, and
    /// a host taken out of its parent drops the window's first responder, which a terminal hears as
    /// focus out and in): while the screen is zoomed or a zoom is in flight, a host stays where it is.
    func hostParent(for pane: PaneID) -> NSView {
        if zoomed || zoomMotion.pane != nil, let host = context.hosts[pane], holds(host), let parent = host.superview { return parent }
        guard !isCanvas, geometry.scrolls(pane: pane) else { return self }
        return scrollerContainer(of: pane) ?? stripContainer
    }

    /// Clips the strip container to the strip's range (`clip`, `PaneArrival.stripClip`, which follows
    /// a dock the CPU grows in; the whole screen without docked columns): one frame for every strip pane,
    /// set only when the range moved. A dock on the render server springs the container's bounds instead
    /// (``springStripContainer(from:velocity:on:landed:)``), which leaves it at the rest range this places. A zoom
    /// keeps the range it found (the zoomed layout has no docks, and the panes it covers stay as they
    /// were) and, when the zooming pane is in the container, lifts the container to the screen's bounds.
    /// Returns true when the container's frame moved.
    func placeStripContainer(_ clip: CGRect?) -> Bool {
        guard !isCanvas else { return false }
        let range = clip ?? (zoomMotion.pane != nil ? stripContainer.range : bounds)
        return stripContainer.place(range: range, liftedTo: liftsStripContainer ? bounds : nil)
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
        case is StripClipContainerView:
            // Lifted with its zooming pane above the docks; under the covered docks while a dock's pane zooms in.
            if liftsStripContainer { return 10 }
            return zoomMotion.pane != nil && !covered.isEmpty ? -2 : 0
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
        case let container as ScrollerPanContainerView:
            // Above the strip's other hosts while the pane zooming in it grows over them.
            guard let pane = zoomMotion.pane, let host = context.hosts[pane] else { return 0 }
            return host.isDescendant(of: container) ? 10 : 0
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

    /// Puts each host in its parent (`hostParent`), then reorders subviews only when the order is
    /// wrong. A host changes parent only when its pane docks or undocks or the screen becomes or stops
    /// being a canvas, never for a zoom or for docks coming or going. `sortSubviews` keeps every view
    /// in the window (no detach), so terminal surfaces and page windows are not torn down.
    func ensureStacking() {
        coverVersion &+= 1
        reconcileScrollerContainers()
        // A zoom's covered panes left `paneFrames`: they stay where they are, under the zooming pane.
        for pane in paneFrames.keys {
            guard let host = context.hosts[pane], holds(host) else { continue }
            let parent = hostParent(for: pane)
            if host.superview !== parent { move(host, to: parent) }
        }
        // With `motion.renderServer` on, the strip's dividers move with its hosts (`ScreenContentView+StripPan`).
        let dividersInContainer = dividersInStripContainer
        stripDividersInContainer = dividersInContainer
        for (kind, view) in dividerViews {
            let parent = dividerParent(for: kind, inContainer: dividersInContainer)
            if view.superview !== parent { parent.addSubview(view) }
        }
        sortByRank(self)
        sortByRank(stripContainer)
        for container in scrollerContainers.values { sortByRank(container) }
        pruneScrollerContainers()
    }

    /// Moves `view` (a host, or a row's or scroll area's container of hosts) under `parent`, giving the
    /// window's first responder back when it was in `view` (a focused pane that docks, or whose area's
    /// container changes parent, keeps its keys).
    func move(_ view: NSView, to parent: NSView) {
        let responder = window?.firstResponder as? NSView
        let focused = responder.map { $0.isDescendant(of: view) } ?? false
        parent.addSubview(view)
        if focused, let responder, window?.firstResponder !== responder { window?.makeFirstResponder(responder) }
    }

    private func sortByRank(_ view: NSView) {
        let ranks = view.subviews.enumerated().map { rank($1) * 100_000 + $0 }
        guard ranks != ranks.sorted() else { return }
        StackingTable(ranks: Dictionary(zip(view.subviews.map(ObjectIdentifier.init), ranks), uniquingKeysWith: { first, _ in first })).sort(view)
    }

    // memory: fixed computed on each read and kept by no one: one rect per laid-out pane.
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

/// Sort keys for `ensureStacking` and the canvas order, lent to `sortSubviews`' comparator for one call.
nonisolated struct StackingTable {
    let ranks: [ObjectIdentifier: Int]

    /// Orders `view`'s subviews by rank. The comparator's context points at a copy of this table that lives
    /// for the call alone (`sortSubviews` is synchronous), not at an object it would have to keep alive.
    @MainActor func sort(_ view: NSView) {
        var table = self
        // SAFETY: the pointer is valid inside this closure, which `sortSubviews` does not outlive.
        unsafe withUnsafeMutablePointer(to: &table) { table in
            // SAFETY: as above; compareStacking only reads through it.
            unsafe view.sortSubviews(compareStacking, context: UnsafeMutableRawPointer(table))
        }
    }
}

/// `sortSubviews` comparator: reads only the ranks of the table ``StackingTable/sort(_:)`` lent it.
nonisolated func compareStacking(_ a: NSView, _ b: NSView, _ context: UnsafeMutableRawPointer?) -> ComparisonResult {
    // SAFETY: a non-nil context is the StackingTable `sort` lent for the sortSubviews call this runs inside.
    guard let ranks = unsafe context?.assumingMemoryBound(to: StackingTable.self).pointee.ranks else { return .orderedSame }
    let x = ranks[ObjectIdentifier(a)] ?? 0
    let y = ranks[ObjectIdentifier(b)] ?? 0
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
