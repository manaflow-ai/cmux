public import CoreGraphics

/// Scroll areas in a screen's geometry (plans/cmux-next/scroll-areas-DESIGN.md).
nonisolated extension ScreenGeometry {
    /// `pane`'s frame for directional focus (K1): inside a scroll area, mapped into the area's
    /// window in proportion (``ScrollAreaGeometry/navigationRect(_:)``); else its frame.
    public func navigationRect(of pane: PaneID) -> CGRect? {
        guard let rect = panes[pane] else { return nil }
        guard let id = scrollAreaOfPane[pane], let area = scrollAreas[id] else { return rect }
        return area.navigationRect(rect)
    }

    /// The window of the scroll area holding `pane`, if any (content space).
    public func scrollAreaWindow(of pane: PaneID) -> CGRect? {
        scrollAreaOfPane[pane].flatMap { scrollAreas[$0]?.window }
    }

    /// Lays out one top-level tree (a split screen, a column, a docked column or a row) in
    /// `frame`: as today, or, when it cannot fit and scroll areas are on, at its minimum width
    /// as a scroll area shown through `frame` (G1, G2). Records the area.
    mutating func layoutTree(_ root: SplitNode, in frame: CGRect, style: LayoutStyle, scale: CGFloat) -> SplitLayoutResult {
        guard let overflow = ScrollAreaGeometry.overflow(of: root, in: frame, style: style, scale: scale) else {
            return SplitGeometry.layout(root, in: frame, style: style, scale: scale)
        }
        let result = SplitGeometry.layout(root, in: overflow.content, style: style, scale: scale)
        let cells = ScrollAreaGeometry.cells(of: root).map { cell in
            let panes = cell.panes
            let frames = Dictionary(uniqueKeysWithValues: panes.compactMap { pane in result.panes[pane].map { (pane, $0) } })
            return ScrollAreaGeometry.Cell(panes: panes, frame: frames.values.reduce(CGRect.null) { $0.union($1) }, paneFrames: frames)
        }
        let area = ScrollAreaGeometry(id: overflow.id, window: frame, contentWidth: overflow.content.width, panes: root.panes,
                                      cells: cells, splits: root.splits)
        scrollAreas[area.id] = area
        for pane in area.panes { scrollAreaOfPane[pane] = area.id }
        for split in area.splits { scrollAreaOfSplit[split] = area.id }
        return result
    }

    /// This geometry with each scroll area's panes and dividers moved left by its offset
    /// (`offsets`, content points) and each pane cut to its area's window: what the view shows,
    /// hit-tests and drops on. A pane wholly outside the window keeps a zero-wide rect at the
    /// window's nearer edge, so nothing outside the window resolves to it. Area windows stay.
    public func shiftingAreas(_ offsets: [SplitID: CGFloat]) -> ScreenGeometry {
        guard !scrollAreas.isEmpty else { return self }
        let live = offsets.filter { $0.value != 0 && scrollAreas[$0.key] != nil }
        var shifted = self
        for (pane, id) in scrollAreaOfPane {
            guard let window = scrollAreas[id]?.window, let rect = panes[pane] else { continue }
            let moved = rect.offsetBy(dx: -(live[id] ?? 0), dy: 0)
            let shown = moved.intersection(window)
            shifted.panes[pane] = shown.isNull || shown.width <= 0
                ? CGRect(x: moved.maxX <= window.minX ? window.minX : window.maxX, y: moved.minY, width: 0, height: moved.height)
                : shown
        }
        guard !live.isEmpty else { return shifted }
        shifted.dividers = dividers.map { divider in
            guard let area = scrollAreaOfSplit[divider.id], let dx = live[area] else { return divider }
            var moved = divider
            moved.frame = divider.frame.offsetBy(dx: -dx, dy: 0)
            moved.hitFrame = divider.hitFrame.offsetBy(dx: -dx, dy: 0)
            moved.container = divider.container.offsetBy(dx: -dx, dy: 0)
            return moved
        }
        return shifted
    }
}
