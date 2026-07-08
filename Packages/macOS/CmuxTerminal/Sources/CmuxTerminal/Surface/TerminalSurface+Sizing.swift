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

    /// Applies a new backing size/scale to the runtime surface.
    ///
    /// - Parameter width: The logical surface width in points.
    /// - Parameter height: The logical surface height in points.
    /// - Parameter xScale: The horizontal backing scale.
    /// - Parameter yScale: The vertical backing scale.
    /// - Parameter layerScale: The backing scale assigned to the hosting layer.
    /// - Parameter backingSize: The precomputed backing size in pixels, if available.
    /// - Parameter coalescePixelOnlyResize: Whether same-grid pixel-only resizes should be skipped.
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
        coalescePixelOnlyResize: Bool = false
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
        let wpx = fittedSize.width
        let hpx = fittedSize.height
        guard wpx > 0, hpx > 0 else { return false }

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

        // Remote tmux display surfaces: keep the remote tmux client sized to
        // the rendered grid, and report only real cell-grid changes while the
        // surface is on screen.
        if manualIO, let report = onManualGridResize, attachedView?.window != nil {
            let grid = ghostty_surface_size(surface)
            let cols = Int(grid.columns)
            let rows = Int(grid.rows)
            if cols > 1, rows > 1,
               lastReportedManualGrid?.columns != cols || lastReportedManualGrid?.rows != rows {
                lastReportedManualGrid = (cols, rows)
                report(cols, rows)
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
