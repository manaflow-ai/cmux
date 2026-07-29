public import AppKit
public import Foundation
public import GhosttyKit

// MARK: - Surface sizing and scale

extension TerminalSurface {
    /// Match upstream Ghostty AppKit sizing: framebuffer dimensions are derived
    /// from backing-space points and truncated (never rounded up).
    func pixelDimension(from value: CGFloat) -> UInt32 {
        guard value.isFinite else { return 0 }
        let floored = floor(max(0, value))
        if floored >= CGFloat(UInt32.max) {
            return UInt32.max
        }
        return UInt32(floored)
    }

    @MainActor
    func scaleFactors(for view: any TerminalSurfaceNativeViewing) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let scale = max(
            1.0,
            view.window?.backingScaleFactor
                ?? view.layer?.contentsScale
                ?? NSScreen.main?.backingScaleFactor
                ?? 1.0
        )
        return (scale, scale, scale)
    }

    func scaleApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    /// Returns whether a backing-pixel resize should be forwarded to Ghostty.
    ///
    /// Ghostty uses one surface-size API for both renderer pixels and PTY
    /// geometry. During AppKit live resize, pixel churn can arrive without a
    /// terminal grid change; coalescing those pixel-only updates avoids
    /// redundant PTY resizes while preserving ordinary layout and scale changes.
    ///
    /// - Parameter currentColumns: The current terminal grid column count.
    /// - Parameter currentRows: The current terminal grid row count.
    /// - Parameter currentWidthPx: The current raw surface width in pixels.
    /// - Parameter currentHeightPx: The current raw surface height in pixels.
    /// - Parameter currentCellWidthPx: The current terminal cell width in pixels.
    /// - Parameter currentCellHeightPx: The current terminal cell height in pixels.
    /// - Parameter targetWidthPx: The candidate surface width in pixels.
    /// - Parameter targetHeightPx: The candidate surface height in pixels.
    /// - Parameter coalescePixelOnlyResize: Whether same-grid pixel-only resizes should be skipped.
    /// - Parameter hasAppliedPixelSize: Whether a previous runtime pixel size has been applied.
    /// - Returns: `true` when Ghostty should receive the new pixel size.
    public static func shouldApplySurfacePixelSizeChange(
        currentColumns: UInt32,
        currentRows: UInt32,
        currentWidthPx: UInt32,
        currentHeightPx: UInt32,
        currentCellWidthPx: UInt32,
        currentCellHeightPx: UInt32,
        targetWidthPx: UInt32,
        targetHeightPx: UInt32,
        coalescePixelOnlyResize: Bool,
        hasAppliedPixelSize: Bool
    ) -> Bool {
        guard hasAppliedPixelSize else { return true }
        guard coalescePixelOnlyResize else { return true }
        guard currentColumns > 0,
              currentRows > 0,
              currentCellWidthPx > 0,
              currentCellHeightPx > 0 else {
            return true
        }

        let cellWidth = UInt64(currentCellWidthPx)
        let cellHeight = UInt64(currentCellHeightPx)
        let currentColumnCount = UInt64(currentColumns)
        let currentRowCount = UInt64(currentRows)
        func mayChangeGrid(
            currentCount: UInt64,
            currentPixels: UInt64,
            cellPixels: UInt64,
            targetPixels: UInt64
        ) -> Bool {
            let currentGridPixels = currentCount * cellPixels
            guard targetPixels >= currentGridPixels else { return true }

            let nextGridPixels = currentGridPixels + cellPixels
            let paddingLower = currentPixels >= nextGridPixels ? currentPixels - nextGridPixels + 1 : 0
            let paddingUpper = currentPixels > currentGridPixels ? currentPixels - currentGridPixels : 0
            let unchangedLower = targetPixels >= nextGridPixels ? targetPixels - nextGridPixels + 1 : 0
            let unchangedUpper = targetPixels - currentGridPixels
            // Coalesce only when every padding value compatible with the current grid stays same-grid.
            return unchangedLower > paddingLower || unchangedUpper < paddingUpper
        }

        return mayChangeGrid(
            currentCount: currentColumnCount,
            currentPixels: UInt64(currentWidthPx),
            cellPixels: cellWidth,
            targetPixels: UInt64(targetWidthPx)
        ) || mayChangeGrid(
            currentCount: currentRowCount,
            currentPixels: UInt64(currentHeightPx),
            cellPixels: cellHeight,
            targetPixels: UInt64(targetHeightPx)
        )
    }

    /// The pixel size that renders exactly an assigned grid: each axis is
    /// the assignment's cells at the current cell size plus the surface's
    /// own chrome, whether the view is shorter or longer. Pure so the
    /// arithmetic is testable without a runtime surface.
    static func assignedGridPinnedSize(
        width: UInt32,
        height: UInt32,
        assignedColumns: Int,
        assignedRows: Int,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        padWidthPx: UInt32,
        padHeightPx: UInt32
    ) -> (width: UInt32, height: UInt32) {
        guard cellWidthPx > 0, cellHeightPx > 0, assignedColumns > 0, assignedRows > 0 else {
            return (width, height)
        }
        return (
            UInt32(assignedColumns) * cellWidthPx + padWidthPx,
            UInt32(assignedRows) * cellHeightPx + padHeightPx
        )
    }

    /// Sets the tmux-assigned grid for a manual-IO mirror pane and
    /// re-applies the current size when the pin changes the applied grid.
    /// Returns whether the pin grew on either axis — cells granted after
    /// tmux already streamed their rows hold nothing until tmux repaints,
    /// so the caller owes a redraw kick when this returns true.
    @MainActor
    @discardableResult
    public func setAssignedGrid(columns: Int, rows: Int) -> Bool {
        let assigned = (columns: columns, rows: rows)
        if let existing = assignedGrid, existing == assigned { return false }
        let grew = assignedGrid.map { columns > $0.columns || rows > $0.rows } ?? true
        assignedGrid = assigned
        reapplyAssignedGrid()
        return grew
    }

    /// Clears the pin (the pane left the mirror tree); the next genuine
    /// resize re-derives the grid from the view alone.
    @MainActor
    public func clearAssignedGrid() {
        guard assignedGrid != nil else { return }
        assignedGrid = nil
        reapplyAssignedGrid()
    }

    /// Re-applies the current pin's pixel size to the surface. The mirror
    /// calls this when a pane's rendered grid falls behind an assignment the
    /// pin already holds — an unchanged ``setAssignedGrid`` is a no-op, so the
    /// surface needs an explicit nudge back onto the pinned grid.
    @MainActor
    public func reapplyAssignedGrid() {
        guard manualIO, lastUncappedPixelWidth > 0, lastUncappedPixelHeight > 0,
              lastXScale > 0, lastYScale > 0 else { return }
        _ = updateSize(
            width: CGFloat(lastUncappedPixelWidth) / lastXScale,
            height: CGFloat(lastUncappedPixelHeight) / lastYScale,
            xScale: lastXScale,
            yScale: lastYScale,
            layerScale: lastXScale
        )
    }

    /// Applies a new backing size/scale to the runtime surface.
    ///
    /// - Parameter width: The logical surface width in points.
    /// - Parameter height: The logical surface height in points.
    /// - Parameter xScale: The horizontal backing scale.
    /// - Parameter yScale: The vertical backing scale.
    /// - Parameter layerScale: The backing scale assigned to the hosting layer.
    /// - Parameter backingSize: The precomputed backing size in pixels, if available.
    /// - Parameter coalescePixelOnlyResize: Whether same-grid pixel-only resizes should be skipped.
    /// - Parameter suppressAssignedGridPin: Skip the tmux-assigned grid pin for this
    ///   resize and use the view-derived size. Set while an interactive resize is
    ///   active: the pin holds the surface at the pre-drag (larger) assignment across
    ///   the whole drag, and presenting that oversized grid before the deferred
    ///   reconcile clamps it paints past the shrinking pane onto siblings. The pin
    ///   re-establishes at rest (drag end and tmux's layout reply both size the pane).
    /// - Returns: Whether a runtime size or scale change was applied.
    @discardableResult
    @MainActor
    public func updateSize(
        width: CGFloat,
        height: CGFloat,
        xScale: CGFloat,
        yScale: CGFloat,
        layerScale: CGFloat,
        backingSize: CGSize? = nil,
        coalescePixelOnlyResize: Bool = false,
        suppressAssignedGridPin: Bool = false
    ) -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "updateSize") else { return false }
        _ = layerScale

        let resolvedBackingWidth = backingSize?.width ?? (width * xScale)
        let resolvedBackingHeight = backingSize?.height ?? (height * yScale)
        let rawWpx = pixelDimension(from: resolvedBackingWidth)
        let rawHpx = pixelDimension(from: resolvedBackingHeight)
        lastUncappedPixelWidth = rawWpx
        lastUncappedPixelHeight = rawHpx
        let fittedSize = mobileViewportFittedSize(
            width: rawWpx,
            height: rawHpx,
            surface: surface,
            reason: "updateSize"
        )
        var wpx = fittedSize.width
        var hpx = fittedSize.height
        guard wpx > 0, hpx > 0 else { return false }

        // The tmux-assigned grid outranks the view's points on a mirror,
        // in BOTH directions: a wider grid never sets wrap flags where
        // tmux wrapped, a taller grid keeps stale rows tmux never
        // repaints, a shorter grid drops assigned cells. Pin the applied
        // pixels to exactly the assignment and let the view clip or
        // letterbox the difference. Skipped until the surface has real
        // cell metrics (a pre-font surface reports zero cells).
        if manualIO, !suppressAssignedGridPin, let assigned = assignedGrid {
            let current = ghostty_surface_size(surface)
            if current.cell_width_px > 0, current.cell_height_px > 0 {
                // On a scale change the reported cell metrics are still at the
                // OLD backing scale — set_content_scale runs later in this
                // method. Pinning the old cell px on a 1x→2x move would pin
                // ~half the columns, and forcing wpx to the old backing width
                // makes sizeChanged false, defeating deferScaleUntilResized
                // (the grid then collapses when the bigger cell lands over the
                // un-resized screen). Project the reported cell (and pad) to
                // the scale this resize is about to apply. Both ratios are 1
                // when the scale is unchanged, so this is a no-op then.
                let ratioX = lastXScale > 0 ? xScale / lastXScale : 1
                let ratioY = lastYScale > 0 ? yScale / lastYScale : 1
                let targetCellW = UInt32(max(1, (CGFloat(current.cell_width_px) * ratioX).rounded()))
                let targetCellH = UInt32(max(1, (CGFloat(current.cell_height_px) * ratioY).rounded()))
                let gridWidthPx = UInt32(current.columns) * current.cell_width_px
                let gridHeightPx = UInt32(current.rows) * current.cell_height_px
                let padWidthPx = current.width_px > gridWidthPx ? current.width_px - gridWidthPx : 0
                let padHeightPx = current.height_px > gridHeightPx ? current.height_px - gridHeightPx : 0
                let pinned = Self.assignedGridPinnedSize(
                    width: wpx,
                    height: hpx,
                    assignedColumns: assigned.columns,
                    assignedRows: assigned.rows,
                    cellWidthPx: targetCellW,
                    cellHeightPx: targetCellH,
                    padWidthPx: UInt32((CGFloat(padWidthPx) * ratioX).rounded()),
                    padHeightPx: UInt32((CGFloat(padHeightPx) * ratioY).rounded())
                )
                #if DEBUG
                if pinned.width != wpx || pinned.height != hpx {
                    Self.sizeLog(
                        "assignedGridPin surface=\(id.uuidString.prefix(8)) " +
                        "assigned=\(assigned.columns)x\(assigned.rows) " +
                        "view=\(wpx)x\(hpx) -> \(pinned.width)x\(pinned.height)"
                    )
                }
                #endif
                wpx = pinned.width
                hpx = pinned.height
            }
        }

        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale) || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = wpx != lastPixelWidth || hpx != lastPixelHeight

        #if DEBUG
        Self.sizeLog("updateSize-call surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) changed=\((scaleChanged || sizeChanged) ? 1 : 0)")
        #endif

        if mobileViewportCellLimit != nil {
            updateMobileViewportBorder(
                appliedWidth: wpx,
                appliedHeight: hpx,
                baseWidth: rawWpx,
                baseHeight: rawHpx
            )
        }

        guard scaleChanged || sizeChanged || fittedSize.fontChanged else { return false }

        #if DEBUG
        if sizeChanged {
            let win = attachedView?.window != nil ? "1" : "0"
            Self.sizeLog("updateSize surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) win=\(win)")
        }
        #endif

        // Apply the cell-size (set_content_scale) and screen-px (set_size) updates
        // in an order that never transiently shrinks the grid (= screen_px /
        // cell_px). Scale-first is fine except on a DPI increase, where the bigger
        // cell over the not-yet-resized screen collapses the grid and truncates a
        // manual-IO mirror's buffer — and a DPI move leaves the remote PTY size
        // unchanged, so nothing repaints it back. Defer the scale past set_size in
        // that case.
        let deferScaleUntilResized = scaleChanged && sizeChanged && (xScale > lastXScale || yScale > lastYScale)
        if scaleChanged && !deferScaleUntilResized {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        if sizeChanged {
            // Coalesce pixel-only resizes first: if the candidate pixel size
            // doesn't change the terminal grid, skip the resize entirely. This
            // must run before any DECAWM toggling below so a coalesced (skipped)
            // resize never leaves a manual-I/O pane with DECAWM disabled.
            let currentSize = ghostty_surface_size(surface)
            let shouldApplySizeChange = Self.shouldApplySurfacePixelSizeChange(
                currentColumns: UInt32(currentSize.columns),
                currentRows: UInt32(currentSize.rows),
                currentWidthPx: currentSize.width_px,
                currentHeightPx: currentSize.height_px,
                currentCellWidthPx: currentSize.cell_width_px,
                currentCellHeightPx: currentSize.cell_height_px,
                targetWidthPx: wpx,
                targetHeightPx: hpx,
                coalescePixelOnlyResize: coalescePixelOnlyResize && !scaleChanged,
                hasAppliedPixelSize: lastPixelWidth > 0 && lastPixelHeight > 0
            )
            guard shouldApplySizeChange else {
                #if DEBUG
                Self.sizeLog(
                    "updateSize-skip-pixel-only surface=\(id.uuidString.prefix(8)) " +
                    "size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
                    "grid=\(currentSize.columns)x\(currentSize.rows) " +
                    "cell=\(currentSize.cell_width_px)x\(currentSize.cell_height_px)"
                )
                #endif
                if fittedSize.fontChanged {
                    ghostty_surface_refresh(surface)
                }
                return scaleChanged || fittedSize.fontChanged
            }

            // Mirror (manual-I/O) surfaces must not reflow their primary screen
            // on resize. tmux is authoritative for pane reflow and streams only
            // incremental post-SIGWINCH redraws, so a local reflow diverges from
            // the tmux grid. Ghostty reflows iff DECAWM is enabled at resize
            // time, so disable it across the size change for TUI-like panes.
            let suppressManualReflow = manualIO && manualIONoReflow
            if suppressManualReflow {
                writeProcessOutputData(Self.decawmDisableSequence, to: surface)
            }
            ghostty_surface_set_size(surface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
            if manualIO {
                // Async refresh, not render_now: render_now runs updateFrame on
                // the main thread and races the always-live macOS renderer
                // thread on a grid-size change (shaper double-free). Keep the
                // DECAWM re-enable after the resize so no-reflow ordering holds.
                ghostty_surface_refresh(surface)
                if suppressManualReflow {
                    writeProcessOutputData(Self.decawmEnableSequence, to: surface)
                }
            }
        }

        if fittedSize.fontChanged && !sizeChanged {
            ghostty_surface_refresh(surface)
        }

        // Deferred from above on a DPI increase: now that set_size grew the grid,
        // applying the larger cell only shrinks it back to the final width.
        if deferScaleUntilResized {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        // Remote tmux display surfaces: report every APPLIED resize —
        // including same-grid re-applies, since a resize that lands on new
        // pixels without changing cols×rows still refines the measured
        // padding constants (surface_px − cols·cell_px). Window attachment is
        // deliberately the ONLY visibility gate: surfaces on unselected tabs
        // must still report, because a hidden mirror's one-time size claim
        // (see RemoteTmuxWindowMirror.updateClientSize) is triggered by its
        // surfaces' first applied resize — the LISTENER owns the policy of
        // what a hidden report may do.
        if manualIO, let report = onManualSizeApplied {
            if let attachedView, attachedView.window != nil {
                manualSizeReportPendingWindowAttach = false
                let applied = ghostty_surface_size(surface)
                let cols = Int(applied.columns)
                let rows = Int(applied.rows)
                if cols > 1, rows > 1 {
                    report(TerminalSurfaceRawSizingSample(
                        columns: cols, rows: rows,
                        cellWidthPx: Int(applied.cell_width_px),
                        cellHeightPx: Int(applied.cell_height_px),
                        surfaceWidthPx: Int(applied.width_px),
                        surfaceHeightPx: Int(applied.height_px),
                        viewBoundsPt: attachedView.bounds.size,
                        backingScale: attachedView.window?.backingScaleFactor
                    ))
                }
            } else {
                // Off-window apply (portal churn during attach, hidden tab
                // setup): remember that a report is owed. If the grid is
                // already final when the view enters a window, no further
                // apply will fire — the attach flush is the only delivery.
                manualSizeReportPendingWindowAttach = true
            }
        }

        // Let Ghostty continue rendering on its own wakeups for steady-state frames.
        return true
    }

    /// The current monospace cell size in points, or nil if the runtime
    /// surface is not ready. Used by remote tmux mirror sizing.
    @MainActor
    public func cellSizePoints() -> CGSize? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "cellSize") else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        let scale = max(Double(lastXScale), 1)
        return CGSize(
            width: Double(size.cell_width_px) / scale,
            height: Double(size.cell_height_px) / scale
        )
    }

    /// Raw sizing sample for calibration diagnostics: `ghostty_surface_size`'s
    /// device-pixel fields UNCONVERTED, plus the attached view's bounds in
    /// points and its window's backing scale. Callers separate view layout,
    /// scale, padding, and cell quantization themselves — pre-mixed units are
    /// how sizing bugs hide (call sites have treated the raw pixel cell size
    /// as points in one place and as pixels in another).
    @MainActor
    public func rawSizingSample() -> TerminalSurfaceRawSizingSample? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "rawSizingSample") else { return nil }
        let size = ghostty_surface_size(surface)
        return TerminalSurfaceRawSizingSample(
            columns: Int(size.columns),
            rows: Int(size.rows),
            cellWidthPx: Int(size.cell_width_px),
            cellHeightPx: Int(size.cell_height_px),
            surfaceWidthPx: Int(size.width_px),
            surfaceHeightPx: Int(size.height_px),
            viewBoundsPt: attachedView?.bounds.size,
            backingScale: attachedView?.window?.backingScaleFactor
        )
    }

    /// Delivers the manual-size report that was skipped because the view was
    /// outside any window when the size applied (see
    /// ``manualSizeReportPendingWindowAttach``). Called from the attach path;
    /// a no-op unless a report is actually owed and deliverable.
    @MainActor
    public func flushPendingManualSizeReportIfAttached() {
        guard manualSizeReportPendingWindowAttach,
              let report = onManualSizeApplied,
              attachedView?.window != nil,
              let sample = rawSizingSample(),
              sample.columns > 1, sample.rows > 1
        else { return }
        manualSizeReportPendingWindowAttach = false
        report(sample)
    }

    /// Which of ``renderedGridCells()``'s nil conditions currently hold —
    /// lets sizing diagnostics name the mechanism (view detached from its
    /// window vs surface not live vs no real grid) instead of a bare nil.
    @MainActor
    public func renderedGridDiagnostics() -> (viewInWindow: Bool, surfaceLive: Bool) {
        (
            viewInWindow: attachedView?.window != nil,
            surfaceLive: liveSurfaceForGhosttyAccess(reason: "renderedGridDiagnostics") != nil
        )
    }

    /// The on-screen rendered grid, or nil while the runtime surface is not
    /// live, is not in a window, or has no real grid yet.
    @MainActor
    public func renderedGridCells() -> (columns: Int, rows: Int)? {
        guard attachedView?.window != nil,
              let surface = liveSurfaceForGhosttyAccess(reason: "renderedGridCells") else { return nil }
        let size = ghostty_surface_size(surface)
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        guard cols > 1, rows > 1 else { return nil }
        return (cols, rows)
    }

}
