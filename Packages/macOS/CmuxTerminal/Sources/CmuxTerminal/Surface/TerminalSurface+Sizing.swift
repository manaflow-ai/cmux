public import AppKit
internal import CmuxTerminalCore
public import Foundation
public import GhosttyKit

// MARK: - Surface sizing, scale, and mobile viewport caps

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

    /// Caps the surface grid to a paired iPhone's viewport.
    ///
    /// - Returns: The actual cell grid applied after capping to the Mac pane, or
    ///   `nil` when no live runtime surface is available.
    @discardableResult
    @MainActor
    public func applyMobileViewportLimit(
        columns: Int,
        rows: Int,
        reason: String
    ) -> (columns: Int, rows: Int)? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "applyMobileViewportLimit") else {
            paneHost.setMobileViewportBorder(size: nil, drawRight: false, drawBottom: false)
            return nil
        }
        if manualIO {
            // Remote/tmux mirrors keep legacy capping; their remote grid is
            // authoritative and font fitting is intentionally out of v1 scope.
            return legacyApplyMobileViewportLimit(
                surface: surface,
                columns: columns,
                rows: rows,
                reason: reason
            )
        }
        mobileViewportCellLimit = (columns: max(1, columns), rows: max(1, rows))
        let baseWidth = lastUncappedPixelWidth
        let baseHeight = lastUncappedPixelHeight
        let currentSize = ghostty_surface_size(surface)
        let fallbackPaneWidth = lastPixelWidth > 0 ? lastPixelWidth : currentSize.width_px
        let fallbackPaneHeight = lastPixelHeight > 0 ? lastPixelHeight : currentSize.height_px
        let fit = mobileViewportFittedSize(
            width: baseWidth > 0 ? baseWidth : fallbackPaneWidth,
            height: baseHeight > 0 ? baseHeight : fallbackPaneHeight,
            surface: surface,
            reason: reason
        )
        guard fit.width > 0, fit.height > 0 else { return nil }

        let appliedWidth = fit.width
        let appliedHeight = fit.height
        let sizeChanged = appliedWidth != lastPixelWidth || appliedHeight != lastPixelHeight
        updateMobileViewportBorder(
            appliedWidth: appliedWidth,
            appliedHeight: appliedHeight,
            baseWidth: baseWidth > 0 ? baseWidth : appliedWidth,
            baseHeight: baseHeight > 0 ? baseHeight : appliedHeight
        )

        #if DEBUG
        Self.sizeLog(
            "mobileViewportLimit surface=\(id.uuidString.prefix(8)) cells=\(columns)x\(rows) " +
            "capPx=\(fit.grantWidth)x\(fit.grantHeight) appliedPx=\(appliedWidth)x\(appliedHeight) " +
            "basePx=\(baseWidth)x\(baseHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "font=\(String(format: "%.2f", fit.baseFont))->\(String(format: "%.2f", fit.currentFont)) " +
            "changed=\((sizeChanged || fit.fontChanged) ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else {
            if fit.fontChanged {
                ghostty_surface_refresh(surface)
            }
            return (fit.columns, fit.rows)
        }
        ghostty_surface_set_size(surface, appliedWidth, appliedHeight)
        lastPixelWidth = appliedWidth
        lastPixelHeight = appliedHeight
        ghostty_surface_refresh(surface)
        return (fit.columns, fit.rows)
    }

    @MainActor
    private func legacyApplyMobileViewportLimit(
        surface: ghostty_surface_t,
        columns: Int,
        rows: Int,
        reason: String
    ) -> (columns: Int, rows: Int)? {
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        let horizontalNonGridPixels = max(0, Int(size.width_px) - currentColumns * cellWidth)
        let verticalNonGridPixels = max(0, Int(size.height_px) - currentRows * cellHeight)
        let targetWidth = safePixelDimension(
            cellCount: columns,
            cellSize: cellWidth,
            nonGridPixels: horizontalNonGridPixels
        )
        let targetHeight = safePixelDimension(
            cellCount: rows,
            cellSize: cellHeight,
            nonGridPixels: verticalNonGridPixels
        )

        mobileViewportCellLimit = (columns: max(1, columns), rows: max(1, rows))
        let baseWidth = lastUncappedPixelWidth > 0 ? lastUncappedPixelWidth : targetWidth
        let baseHeight = lastUncappedPixelHeight > 0 ? lastUncappedPixelHeight : targetHeight
        let appliedWidth = min(targetWidth, baseWidth)
        let appliedHeight = min(targetHeight, baseHeight)
        let sizeChanged = appliedWidth != lastPixelWidth || appliedHeight != lastPixelHeight
        let appliedColumns = cellCount(
            pixelDimension: appliedWidth,
            cellSize: cellWidth,
            nonGridPixels: horizontalNonGridPixels
        )
        let appliedRows = cellCount(
            pixelDimension: appliedHeight,
            cellSize: cellHeight,
            nonGridPixels: verticalNonGridPixels
        )
        updateMobileViewportBorder(
            appliedWidth: appliedWidth,
            appliedHeight: appliedHeight,
            baseWidth: baseWidth,
            baseHeight: baseHeight
        )

        #if DEBUG
        Self.sizeLog(
            "mobileViewportLimit surface=\(id.uuidString.prefix(8)) cells=\(columns)x\(rows) " +
            "capPx=\(targetWidth)x\(targetHeight) appliedPx=\(appliedWidth)x\(appliedHeight) " +
            "basePx=\(baseWidth)x\(baseHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "changed=\(sizeChanged ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else { return (appliedColumns, appliedRows) }
        ghostty_surface_set_size(surface, appliedWidth, appliedHeight)
        lastPixelWidth = appliedWidth
        lastPixelHeight = appliedHeight
        ghostty_surface_refresh(surface)
        return (appliedColumns, appliedRows)
    }

    /// Removes the mobile viewport cap and restores the uncapped size.
    ///
    /// - Returns: Whether the runtime surface size changed.
    @discardableResult
    @MainActor
    public func clearMobileViewportLimit(reason: String) -> Bool {
        mobileViewportCellLimit = nil
        paneHost.setMobileViewportBorder(size: nil, drawRight: false, drawBottom: false)

        guard let surface = liveSurfaceForGhosttyAccess(reason: "clearMobileViewportLimit") else {
            mobileFitBaseFontPointSize = nil
            mobileFittedFontPointSize = nil
            return false
        }
        let fontRestored = restoreMobileViewportFitFontIfNeeded()
        let uncappedWidth = lastUncappedPixelWidth
        let uncappedHeight = lastUncappedPixelHeight
        guard uncappedWidth > 0, uncappedHeight > 0 else {
            if fontRestored {
                ghostty_surface_refresh(surface)
            }
            return fontRestored
        }

        let sizeChanged = uncappedWidth != lastPixelWidth || uncappedHeight != lastPixelHeight

        #if DEBUG
        Self.sizeLog(
            "clearMobileViewportLimit surface=\(id.uuidString.prefix(8)) " +
            "uncappedPx=\(uncappedWidth)x\(uncappedHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "changed=\((sizeChanged || fontRestored) ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else {
            ghostty_surface_refresh(surface)
            return fontRestored
        }
        ghostty_surface_set_size(surface, uncappedWidth, uncappedHeight)
        lastPixelWidth = uncappedWidth
        lastPixelHeight = uncappedHeight
        ghostty_surface_refresh(surface)
        return true
    }

    @MainActor
    private func mobileViewportFittedSize(
        width: UInt32,
        height: UInt32,
        surface: ghostty_surface_t,
        reason: String
    ) -> (
        width: UInt32,
        height: UInt32,
        columns: Int,
        rows: Int,
        grantWidth: UInt32,
        grantHeight: UInt32,
        baseFont: Float,
        currentFont: Float,
        fontChanged: Bool
    ) {
        guard width > 0, height > 0 else {
            return (width, height, 0, 0, width, height, 0, 0, false)
        }
        guard let mobileViewportCellLimit else {
            return (width, height, 0, 0, width, height, 0, 0, false)
        }
        if manualIO {
            guard let mobileViewportPixelLimit = mobileViewportPixelLimit(for: surface) else {
                return (width, height, 0, 0, width, height, 0, 0, false)
            }
            return (
                width: min(width, mobileViewportPixelLimit.width),
                height: min(height, mobileViewportPixelLimit.height),
                columns: 0,
                rows: 0,
                grantWidth: mobileViewportPixelLimit.width,
                grantHeight: mobileViewportPixelLimit.height,
                baseFont: 0,
                currentFont: 0,
                fontChanged: false
            )
        }

        let grantedColumns = max(1, mobileViewportCellLimit.columns)
        let grantedRows = max(1, mobileViewportCellLimit.rows)
        let paneWidth = max(1, Int(width))
        let paneHeight = max(1, Int(height))
        let baseFont = resolvedMobileViewportBaseFontPointSize(surface: surface)
        var currentFont = mobileFittedFontPointSize
            ?? GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(surface)
            ?? baseFont
        var measurement = mobileViewportMeasurement(surface: surface)
        var targetFont = MobileViewportFitGeometry.integerCellTargetFontPointSize(
            paneWidthPx: paneWidth,
            paneHeightPx: paneHeight,
            measuredCellWidthPx: Double(measurement.cellWidth),
            measuredCellHeightPx: Double(measurement.cellHeight),
            baseFontPointSize: baseFont,
            currentFontPointSize: currentFont,
            columns: grantedColumns,
            rows: grantedRows,
            horizontalNonGridPixels: measurement.horizontalNonGridPixels,
            verticalNonGridPixels: measurement.verticalNonGridPixels
        )
        var fontChanged = false
        var appliedColumns = grantedColumns
        var appliedRows = grantedRows
        var appliedBox = MobileViewportFitGeometry.grantPixelBox(
            columns: grantedColumns,
            rows: grantedRows,
            cellWidthPx: Double(measurement.cellWidth),
            cellHeightPx: Double(measurement.cellHeight),
            horizontalNonGridPixels: measurement.horizontalNonGridPixels,
            verticalNonGridPixels: measurement.verticalNonGridPixels
        )

        for _ in 0..<3 {
            let fontFloor = min(baseFont, MobileViewportFitGeometry.defaultFontFloorPointSize)
            if abs(targetFont - currentFont) >= 0.25 {
                if mobileFitBaseFontPointSize == nil {
                    mobileFitBaseFontPointSize = baseFont
                }
                if applyMobileViewportFontPointSize(targetFont) {
                    mobileFittedFontPointSize = targetFont
                    currentFont = targetFont
                    fontChanged = true
                    measurement = mobileViewportMeasurement(surface: surface)
                }
            }

            appliedColumns = grantedColumns
            appliedRows = grantedRows
            appliedBox = MobileViewportFitGeometry.grantPixelBox(
                columns: grantedColumns,
                rows: grantedRows,
                cellWidthPx: Double(measurement.cellWidth),
                cellHeightPx: Double(measurement.cellHeight),
                horizontalNonGridPixels: measurement.horizontalNonGridPixels,
                verticalNonGridPixels: measurement.verticalNonGridPixels
            )
            if !MobileViewportFitGeometry.needsRefinement(
                grantWidthPx: appliedBox.width,
                grantHeightPx: appliedBox.height,
                paneWidthPx: paneWidth,
                paneHeightPx: paneHeight
            ) {
                return (
                    appliedBox.width,
                    appliedBox.height,
                    appliedColumns,
                    appliedRows,
                    appliedBox.width,
                    appliedBox.height,
                    baseFont,
                    currentFont,
                    fontChanged
                )
            }

            guard currentFont > fontFloor + 0.001 else {
                break
            }

            let nextTarget = MobileViewportFitGeometry.correctiveFontPointSizeForOverflow(
                paneWidthPx: paneWidth,
                paneHeightPx: paneHeight,
                measuredCellWidthPx: Double(measurement.cellWidth),
                measuredCellHeightPx: Double(measurement.cellHeight),
                currentFontPointSize: currentFont,
                columns: grantedColumns,
                rows: grantedRows,
                horizontalNonGridPixels: measurement.horizontalNonGridPixels,
                verticalNonGridPixels: measurement.verticalNonGridPixels
            )
            guard abs(nextTarget - currentFont) > 0.001 else {
                break
            }
            if mobileFitBaseFontPointSize == nil {
                mobileFitBaseFontPointSize = baseFont
            }
            if applyMobileViewportFontPointSize(nextTarget) {
                mobileFittedFontPointSize = nextTarget
                currentFont = nextTarget
                fontChanged = true
                measurement = mobileViewportMeasurement(surface: surface)
                targetFont = nextTarget
            } else {
                break
            }
        }

        appliedBox = MobileViewportFitGeometry.grantPixelBox(
            columns: grantedColumns,
            rows: grantedRows,
            cellWidthPx: Double(measurement.cellWidth),
            cellHeightPx: Double(measurement.cellHeight),
            horizontalNonGridPixels: measurement.horizontalNonGridPixels,
            verticalNonGridPixels: measurement.verticalNonGridPixels
        )
        if !MobileViewportFitGeometry.needsRefinement(
            grantWidthPx: appliedBox.width,
            grantHeightPx: appliedBox.height,
            paneWidthPx: paneWidth,
            paneHeightPx: paneHeight
        ) {
            return (
                appliedBox.width,
                appliedBox.height,
                grantedColumns,
                grantedRows,
                appliedBox.width,
                appliedBox.height,
                baseFont,
                currentFont,
                fontChanged
            )
        }

        let fontFloor = min(baseFont, MobileViewportFitGeometry.defaultFontFloorPointSize)
        if currentFont > fontFloor + 0.001 {
            guard applyMobileViewportFontPointSize(fontFloor) else {
                let fallback = MobileViewportFitGeometry.cappedFallbackGrant(
                    grantedColumns: grantedColumns,
                    grantedRows: grantedRows,
                    paneWidthPx: paneWidth,
                    paneHeightPx: paneHeight,
                    cellWidthPxAtFloor: Double(measurement.cellWidth),
                    cellHeightPxAtFloor: Double(measurement.cellHeight),
                    horizontalNonGridPixels: measurement.horizontalNonGridPixels,
                    verticalNonGridPixels: measurement.verticalNonGridPixels
                )
                return (
                    fallback.width,
                    fallback.height,
                    fallback.columns,
                    fallback.rows,
                    appliedBox.width,
                    appliedBox.height,
                    baseFont,
                    currentFont,
                    fontChanged
                )
            }
            mobileFittedFontPointSize = fontFloor
            currentFont = fontFloor
            fontChanged = true
            measurement = mobileViewportMeasurement(surface: surface)
        }
        appliedBox = MobileViewportFitGeometry.grantPixelBox(
            columns: grantedColumns,
            rows: grantedRows,
            cellWidthPx: Double(measurement.cellWidth),
            cellHeightPx: Double(measurement.cellHeight),
            horizontalNonGridPixels: measurement.horizontalNonGridPixels,
            verticalNonGridPixels: measurement.verticalNonGridPixels
        )
        if !MobileViewportFitGeometry.needsRefinement(
            grantWidthPx: appliedBox.width,
            grantHeightPx: appliedBox.height,
            paneWidthPx: paneWidth,
            paneHeightPx: paneHeight
        ) {
            return (
                appliedBox.width,
                appliedBox.height,
                grantedColumns,
                grantedRows,
                appliedBox.width,
                appliedBox.height,
                baseFont,
                currentFont,
                fontChanged
            )
        }

        let fallback = MobileViewportFitGeometry.cappedFallbackGrant(
            grantedColumns: grantedColumns,
            grantedRows: grantedRows,
            paneWidthPx: paneWidth,
            paneHeightPx: paneHeight,
            cellWidthPxAtFloor: Double(measurement.cellWidth),
            cellHeightPxAtFloor: Double(measurement.cellHeight),
            horizontalNonGridPixels: measurement.horizontalNonGridPixels,
            verticalNonGridPixels: measurement.verticalNonGridPixels
        )
        return (
            fallback.width,
            fallback.height,
            fallback.columns,
            fallback.rows,
            appliedBox.width,
            appliedBox.height,
            baseFont,
            currentFont,
            fontChanged
        )
    }

    private func mobileViewportPixelLimit(for surface: ghostty_surface_t) -> (width: UInt32, height: UInt32)? {
        guard let mobileViewportCellLimit else {
            return nil
        }
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        let horizontalNonGridPixels = max(0, Int(size.width_px) - currentColumns * cellWidth)
        let verticalNonGridPixels = max(0, Int(size.height_px) - currentRows * cellHeight)
        return (
            width: safePixelDimension(
                cellCount: mobileViewportCellLimit.columns,
                cellSize: cellWidth,
                nonGridPixels: horizontalNonGridPixels
            ),
            height: safePixelDimension(
                cellCount: mobileViewportCellLimit.rows,
                cellSize: cellHeight,
                nonGridPixels: verticalNonGridPixels
            )
        )
    }

    private func safePixelDimension(cellCount: Int, cellSize: Int, nonGridPixels: Int) -> UInt32 {
        let clampedCellSize = max(1, cellSize)
        let clampedNonGridPixels = min(max(0, nonGridPixels), Int(UInt32.max) - 1)
        let maxCells = max(1, (Int(UInt32.max) - clampedNonGridPixels) / clampedCellSize)
        let clampedCellCount = min(max(1, cellCount), maxCells)
        return UInt32(clampedCellCount * clampedCellSize + clampedNonGridPixels)
    }

    private func cellCount(pixelDimension: UInt32, cellSize: Int, nonGridPixels: Int) -> Int {
        let gridPixels = max(0, Int(pixelDimension) - max(0, nonGridPixels))
        return max(1, gridPixels / max(1, cellSize))
    }

    @MainActor
    private func mobileViewportMeasurement(
        surface: ghostty_surface_t
    ) -> (
        cellWidth: Int,
        cellHeight: Int,
        horizontalNonGridPixels: Int,
        verticalNonGridPixels: Int
    ) {
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        return (
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            horizontalNonGridPixels: max(0, Int(size.width_px) - currentColumns * cellWidth),
            verticalNonGridPixels: max(0, Int(size.height_px) - currentRows * cellHeight)
        )
    }

    @MainActor
    private func resolvedMobileViewportBaseFontPointSize(surface: ghostty_surface_t) -> Float {
        if let mobileFitBaseFontPointSize {
            return mobileFitBaseFontPointSize
        }
        if let current = GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(surface),
           current.isFinite,
           current > 0 {
            return current
        }
        let baseFont = configTemplate?.fontSize ?? Float(GhosttyConfig().fontSize)
        return CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: baseFont > 0 ? baseFont : Float(GhosttyConfig().fontSize),
            percent: globalFontMagnificationPercent()
        )
    }

    @discardableResult
    @MainActor
    private func restoreMobileViewportFitFontIfNeeded() -> Bool {
        guard mobileFittedFontPointSize != nil,
              let baseFont = mobileFitBaseFontPointSize else {
            mobileFitBaseFontPointSize = nil
            mobileFittedFontPointSize = nil
            return false
        }
        applyMobileViewportFontPointSize(baseFont)
        mobileFitBaseFontPointSize = nil
        mobileFittedFontPointSize = nil
        return true
    }

    @MainActor
    @discardableResult
    private func applyMobileViewportFontPointSize(_ points: Float) -> Bool {
        let action = String(format: "set_font_size:%.3f", points)
        return performBindingAction(action)
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

    @MainActor
    private func updateMobileViewportBorder(
        appliedWidth: UInt32,
        appliedHeight: UInt32,
        baseWidth: UInt32,
        baseHeight: UInt32
    ) {
        let drawRightBorder = appliedWidth < baseWidth
        let drawBottomBorder = appliedHeight < baseHeight
        let borderScale = paneHost.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        paneHost.setMobileViewportBorder(
            size: CGSize(
                width: CGFloat(appliedWidth) / max(1, borderScale),
                height: CGFloat(appliedHeight) / max(1, borderScale)
            ),
            drawRight: drawRightBorder,
            drawBottom: drawBottomBorder
        )
    }
}
