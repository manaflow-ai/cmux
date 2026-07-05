import Foundation

/// The feed-forward sizing math for mirrored tmux windows: one value type
/// holding the measured render constants, exposing the two pure functions the
/// mirror needs — the client size implied by a pixel budget (`clientCells`,
/// "f") and the exact frames an assigned layout occupies inside that budget
/// (`frames`, "g").
///
/// Dataflow discipline (the reason this type exists): f depends only on the
/// pixel budget, the layout tree's STRUCTURE, and these locally-owned
/// constants — never on tmux-assigned geometry or rendered grids — so an echo of
/// our own `refresh-client` push recomputes to the identical size and dedups
/// to silence. g imposes tmux's assigned cells verbatim; nothing measures the
/// render back. Neither function reads mutable state: both are pure over
/// their arguments, computed in DEVICE PIXELS with cumulative edge rails so
/// per-pane rounding error cannot accumulate, and converted to points only at
/// the boundary.
///
/// Constants are measured, not assumed: `cellWidthPx`/`cellHeightPx` and the
/// ghostty padding come from `ghostty_surface_size` on a live surface
/// (calibrated 2026-07-03: `cols == floor((surface_px − pad_w)/cell_px)`
/// exact on 100% of settled samples, pad_w = 8 device px at 2× with the
/// default ghostty config, pad_h = 0; `surface_px == view_pt × scale` exact).
struct RemoteTmuxMirrorGeometry: Equatable, Sendable {
    /// Terminal cell width in device pixels (integer, from ghostty).
    let cellWidthPx: Int
    /// Terminal cell height in device pixels (integer, from ghostty).
    let cellHeightPx: Int
    /// Horizontal ghostty padding per surface in device pixels (both sides
    /// combined — the fixed part of `surface_px − cols·cell_px`).
    let surfacePadWidthPx: Int
    /// Vertical ghostty padding per surface in device pixels (both sides
    /// combined).
    let surfacePadHeightPx: Int
    /// The hosting window's backing scale (1.0 or 2.0 on macOS).
    let scale: CGFloat

    /// The client size (tmux cols × rows) whose layout fits this pixel budget.
    ///
    /// Width: every pane column and every separator column costs exactly
    /// `cellWidthPx`; each pane additionally costs its surface padding, and
    /// the number of panes stacked side by side varies per row of the tree —
    /// the structural fold below accounts both; height is the transpose. The
    /// fold depends only on the tree's
    /// STRUCTURE (pane nesting), never on assigned sizes: sums of assigned cells
    /// along a split collapse to the parent total, so tmux's layout cancels out.
    ///
    /// - Parameter pixelWidth/pixelHeight: the mirror container's size in
    ///   device pixels (points × backing scale).
    /// - Parameter structure: the window's BASE layout tree (never the
    ///   zoomed/visible tree — zoom must not flap the pushed size).
    /// - Returns: cols/rows floored at tmux-workable minimums.
    func clientCells(
        pixelWidth: Int,
        pixelHeight: Int,
        structure: RemoteTmuxLayoutNode
    ) -> (cols: Int, rows: Int) {
        let chrome = Self.chromePx(
            of: structure,
            padW: surfacePadWidthPx,
            padH: surfacePadHeightPx
        )
        let cols = (pixelWidth - chrome.width) / max(1, cellWidthPx)
        // − 1 row: the title band reserved across the top of the mirror
        // (``frames(layout:containerPt:)``). One row TOTAL, not per pane:
        // every pane below the window top already sits under a tmux
        // separator row, so the band is the only strip tmux doesn't provide
        // — and because it is uniform across branches, bottom edges still
        // align regardless of stacking depth. When tmux itself reserves the
        // title rows (pane-border-status: no pane sits at the window top),
        // the band is tmux's and every pushed row is a grid row.
        let band = Self.paneTouchesTop(of: structure) ? 1 : 0
        let rows = (pixelHeight - chrome.height) / max(1, cellHeightPx) - band
        return (cols: max(Self.minCols, cols), rows: max(Self.minRows, rows))
    }

    /// Whether any pane's cell rect starts at the window's top row. False
    /// exactly when tmux inserted a row above every top pane — its
    /// `pane-border-status` title rows — in which case the mirror must not
    /// stack a second, synthetic band on top.
    static func paneTouchesTop(of node: RemoteTmuxLayoutNode) -> Bool {
        switch node.content {
        case .pane:
            // <= 0, not == 0: real tmux offsets are never negative, but
            // trees built programmatically (tests, placeholders) may carry
            // -1 — those must behave like the ordinary no-title-rows case.
            return node.y <= 0
        case let .horizontal(children), let .vertical(children):
            return children.contains { paneTouchesTop(of: $0) }
        }
    }

    /// Floors below which a client size is never pushed: tmux clamps
    /// per-window at the layout minimum anyway (measured: no errors, no
    /// restructures down to 1×1), but a session-visible postage stamp from a
    /// transient degenerate frame is never useful.
    static let minCols = 20
    static let minRows = 5

    /// The pixel cost of everything that is NOT tmux cell grid, folded over
    /// the layout structure. Per pane: the surface padding — the ONLY
    /// off-grid chrome the mirror has. Every other non-content pixel is a
    /// row or column tmux itself allocated (separators, and title rows when
    /// pane-border-status is set), so it lives inside the cell budget and
    /// never appears here. Same-axis splits sum their children;
    /// cross-axis splits take the max. Separator columns/rows are deliberately
    /// absorbed into the CELL budget (a separator costs exactly one cell), so
    /// they never appear here — that collapse is what makes the fold
    /// layout-independent.
    static func chromePx(
        of node: RemoteTmuxLayoutNode,
        padW: Int,
        padH: Int
    ) -> (width: Int, height: Int) {
        switch node.content {
        case .pane:
            return (width: padW, height: padH)
        case let .horizontal(children):
            var width = 0
            var height = 0
            for child in children {
                let c = chromePx(of: child, padW: padW, padH: padH)
                width += c.width
                height = max(height, c.height)
            }
            return (width, height)
        case let .vertical(children):
            var width = 0
            var height = 0
            for child in children {
                let c = chromePx(of: child, padW: padW, padH: padH)
                width = max(width, c.width)
                height += c.height
            }
            return (width, height)
        }
    }

    /// Per-node chrome, both folds, computed in ONE bottom-up pass per
    /// `frames()` call. Placement previously re-ran the recursive
    /// ``chromePx(of:padW:padH:)`` for every child at every level, walking
    /// each subtree once per ancestor — superlinear on pane count. Threading
    /// this tree through ``place`` keeps the whole derivation linear.
    private struct ChromeTree {
        /// ``chromePx``'s width fold with `(padW: surfacePadWidthPx, padH: 0)`.
        let width: Int
        /// ``chromePx``'s height fold with `(padW: 0, padH: surfacePadHeightPx)`.
        let height: Int
        let children: [ChromeTree]
    }

    private func chromeTree(of node: RemoteTmuxLayoutNode) -> ChromeTree {
        switch node.content {
        case .pane:
            return ChromeTree(width: surfacePadWidthPx, height: surfacePadHeightPx, children: [])
        case let .horizontal(children):
            let kids = children.map { chromeTree(of: $0) }
            return ChromeTree(
                width: kids.reduce(0) { $0 + $1.width },
                height: kids.map(\.height).max() ?? 0,
                children: kids
            )
        case let .vertical(children):
            let kids = children.map { chromeTree(of: $0) }
            return ChromeTree(
                width: kids.map(\.width).max() ?? 0,
                height: kids.reduce(0) { $0 + $1.height },
                children: kids
            )
        }
    }

    /// The exact frames an assigned layout occupies inside a container, computed
    /// as integer-device-pixel EDGE RAILS (each edge is the rounded cumulative
    /// spend, so per-pane error never accumulates) and returned in points.
    ///
    /// Split-axis exact, cross-axis fill: a leaf's extent on its split axis
    /// is exactly `cells·cellPx + padding`; on
    /// the cross axis it fills whatever the parent allocated, so asymmetric
    /// trees don't accumulate dead bands. Trailing leftover pixels (budget tmux's
    /// layout doesn't consume) stay at the trailing edge as background.
    ///
    /// - Parameter layout: the window's VISIBLE layout tree (the zoomed
    ///   single-pane tree while zoomed — g renders what tmux displays).
    /// - Parameter containerPt: the mirror container size in points.
    /// - Returns: per-pane frames and divider strips, in points, in the
    ///   container's coordinate space.
    func frames(
        layout: RemoteTmuxLayoutNode,
        containerPt: CGSize
    ) -> RemoteTmuxMirrorFrames {
        var paneFrames: [Int: CGRect] = [:]
        var dividers: [CGRect] = []
        var containerPx = CGRect(
            x: 0, y: 0,
            width: containerPt.width * scale,
            height: containerPt.height * scale
        )
        // The title band: one cell-high strip across the top, the synthetic
        // twin of tmux's separator rows, so EVERY pane has a strip above it
        // (window-top panes get this band; every other pane sits under a
        // tmux separator). The active pane's dot renders in the strip above
        // it — over strip background, never over content. Skipped when tmux
        // reserves the title rows itself (pane-border-status): those arrive
        // as offset gaps below and render as strips without our help.
        if Self.paneTouchesTop(of: layout) {
            let bandPx = CGFloat(cellHeightPx)
            dividers.append(CGRect(
                x: 0, y: 0, width: containerPx.width, height: bandPx
            ))
            containerPx = CGRect(
                x: 0, y: bandPx,
                width: containerPx.width, height: containerPx.height - bandPx
            )
        }
        place(
            layout, chrome: chromeTree(of: layout),
            in: containerPx, cellOrigin: (x: layout.x, y: layout.y),
            paneFrames: &paneFrames, dividers: &dividers
        )
        return RemoteTmuxMirrorFrames(
            paneFramesPt: paneFrames.mapValues { $0.divided(by: scale) },
            dividersPt: dividers.map { $0.divided(by: scale) }
        )
    }

    /// Recursive placement in device pixels. `region` is the pixel rect the
    /// parent allocated to this node and `cellOrigin` the cell coordinate
    /// that rect's top-leading corner corresponds to (cross-axis fill
    /// happens by inheriting the region's cross extent).
    ///
    /// GAPS COME FROM THE TREE'S OWN OFFSETS, never from an assumed one-cell
    /// separator: each child declares its absolute cell position, so
    /// whatever rows or columns tmux inserted between (or above) children —
    /// separators, or per-pane title rows under `pane-border-status` — land
    /// here as strip rects automatically. A hardcoded gap silently
    /// mis-places every pane the moment tmux grows new kinds of chrome.
    private func place(
        _ node: RemoteTmuxLayoutNode,
        chrome: ChromeTree,
        in region: CGRect,
        cellOrigin: (x: Int, y: Int),
        paneFrames: inout [Int: CGRect],
        dividers: inout [CGRect]
    ) {
        switch node.content {
        case .pane(let id):
            paneFrames[id] = region
        case .horizontal(let children):
            // Edge rails: x_k = region.minX + rounded cumulative spend, where
            // each child spends cells·cellPx + its own chrome width and each
            // gap spends exactly the cells the offsets declare.
            var cursor = region.minX
            var cursorCellX = cellOrigin.x
            for (index, child) in children.enumerated() {
                let gapCells = max(0, child.x - cursorCellX)
                if gapCells > 0 {
                    let gapEnd = min(cursor + CGFloat(gapCells * cellWidthPx), region.maxX)
                    dividers.append(CGRect(
                        x: cursor, y: region.minY, width: gapEnd - cursor, height: region.height
                    ))
                    cursor = gapEnd
                    cursorCellX = child.x
                }
                let childChrome = chrome.children[index]
                let spend = CGFloat(child.width * cellWidthPx + childChrome.width)
                let next = (cursor + spend).rounded()
                // A child can also sit BELOW its declared row inside this
                // region (its own title row under pane-border-status): band
                // the skipped rows as a strip and give the child what
                // remains.
                var childTop = region.minY
                let dropCells = max(0, child.y - cellOrigin.y)
                if dropCells > 0 {
                    let bandEnd = min(childTop + CGFloat(dropCells * cellHeightPx), region.maxY)
                    dividers.append(CGRect(
                        x: cursor, y: childTop,
                        width: min(next + 1, region.maxX) - cursor, height: bandEnd - childTop
                    ))
                    childTop = bandEnd
                }
                // +1 device px into the following gap: the frame otherwise sits
                // EXACTLY on the cell-quantization boundary, and any half-pixel
                // lost downstream (point conversion, portal snapping) floors the
                // surface to one column short — a full-width line then wraps.
                // Rails stay exact; the overlap hides under the pane (dividers
                // render below panes).
                let childRegion = CGRect(
                    x: cursor, y: childTop,
                    width: min(next + 1, region.maxX) - cursor,
                    height: region.maxY - childTop
                )
                place(
                    child, chrome: childChrome,
                    in: childRegion, cellOrigin: (x: child.x, y: child.y),
                    paneFrames: &paneFrames, dividers: &dividers
                )
                cursor = next
                cursorCellX = child.x + child.width
            }
        case .vertical(let children):
            var cursor = region.minY
            var cursorCellY = cellOrigin.y
            for (index, child) in children.enumerated() {
                let gapCells = max(0, child.y - cursorCellY)
                if gapCells > 0 {
                    let gapEnd = min(cursor + CGFloat(gapCells * cellHeightPx), region.maxY)
                    dividers.append(CGRect(
                        x: region.minX, y: cursor, width: region.width, height: gapEnd - cursor
                    ))
                    cursor = gapEnd
                    cursorCellY = child.y
                }
                let childChrome = chrome.children[index]
                let spend = CGFloat(child.height * cellHeightPx + childChrome.height)
                let next = (cursor + spend).rounded()
                // Same +1 device px as the horizontal rails (see above).
                let childRegion = CGRect(
                    x: region.minX, y: cursor,
                    width: region.width,
                    height: min(next + 1, region.maxY) - cursor
                )
                place(
                    child, chrome: childChrome,
                    in: childRegion, cellOrigin: (x: child.x, y: child.y),
                    paneFrames: &paneFrames, dividers: &dividers
                )
                cursor = next
                cursorCellY = child.y + child.height
            }
        }
    }
}

extension CGRect {
    /// Scales a device-pixel rect back to points.
    fileprivate func divided(by scale: CGFloat) -> CGRect {
        CGRect(
            x: origin.x / scale,
            y: origin.y / scale,
            width: size.width / scale,
            height: size.height / scale
        )
    }
}
