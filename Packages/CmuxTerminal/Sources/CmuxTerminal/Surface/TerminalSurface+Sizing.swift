public import AppKit
public import Foundation
public import GhosttyKit
internal import QuartzCore
#if DEBUG
internal import CMUXDebugLog
#endif

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
        let rawTargetColumns = max(UInt64(1), UInt64(targetWidthPx) / cellWidth)
        let rawTargetRows = max(UInt64(1), UInt64(targetHeightPx) / cellHeight)
        let currentGridWidthPx = currentColumnCount * cellWidth
        let currentGridHeightPx = currentRowCount * cellHeight
        let horizontalCurrentRemainder = UInt64(currentWidthPx) > currentGridWidthPx
            ? UInt64(currentWidthPx) - currentGridWidthPx
            : 0
        let verticalCurrentRemainder = UInt64(currentHeightPx) > currentGridHeightPx
            ? UInt64(currentHeightPx) - currentGridHeightPx
            : 0
        let adjustedTargetGridWidthPx = UInt64(targetWidthPx) > horizontalCurrentRemainder
            ? UInt64(targetWidthPx) - horizontalCurrentRemainder
            : 0
        let adjustedTargetGridHeightPx = UInt64(targetHeightPx) > verticalCurrentRemainder
            ? UInt64(targetHeightPx) - verticalCurrentRemainder
            : 0
        let adjustedTargetColumns = max(UInt64(1), adjustedTargetGridWidthPx / cellWidth)
        let adjustedTargetRows = max(UInt64(1), adjustedTargetGridHeightPx / cellHeight)
        return rawTargetColumns != currentColumnCount
            || rawTargetRows != currentRowCount
            || adjustedTargetColumns != currentColumnCount
            || adjustedTargetRows != currentRowCount
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
        let cappedSize = cappedByMobileViewportLimit(width: rawWpx, height: rawHpx, surface: surface)
        let wpx = cappedSize.width
        let hpx = cappedSize.height
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

        guard scaleChanged || sizeChanged else { return false }

        #if DEBUG
        if sizeChanged {
            let win = attachedView?.window != nil ? "1" : "0"
            Self.sizeLog("updateSize surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) win=\(win)")
        }
        #endif

        if scaleChanged {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        if sizeChanged {
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
                return scaleChanged
            }
            ghostty_surface_set_size(surface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
        }

        // Let Ghostty continue rendering on its own wakeups for steady-state frames.
        return true
    }

    /// Caps the surface grid to a paired iPhone's viewport.
    ///
    /// - Returns: Whether the runtime surface size changed.
    @discardableResult
    @MainActor
    public func applyMobileViewportLimit(columns: Int, rows: Int, reason: String) -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "applyMobileViewportLimit") else {
            paneHost.setMobileViewportBorder(size: nil, drawRight: false, drawBottom: false)
            return false
        }
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

        guard sizeChanged else { return false }
        ghostty_surface_set_size(surface, appliedWidth, appliedHeight)
        lastPixelWidth = appliedWidth
        lastPixelHeight = appliedHeight
        ghostty_surface_refresh(surface)
        return true
    }

    /// Removes the mobile viewport cap and restores the uncapped size.
    ///
    /// - Returns: Whether the runtime surface size changed.
    @discardableResult
    @MainActor
    public func clearMobileViewportLimit(reason: String) -> Bool {
        mobileViewportCellLimit = nil
        paneHost.setMobileViewportBorder(size: nil, drawRight: false, drawBottom: false)

        let uncappedWidth = lastUncappedPixelWidth
        let uncappedHeight = lastUncappedPixelHeight
        guard let surface = liveSurfaceForGhosttyAccess(reason: "clearMobileViewportLimit"),
              uncappedWidth > 0,
              uncappedHeight > 0 else {
            return false
        }

        let sizeChanged = uncappedWidth != lastPixelWidth || uncappedHeight != lastPixelHeight

        #if DEBUG
        Self.sizeLog(
            "clearMobileViewportLimit surface=\(id.uuidString.prefix(8)) " +
            "uncappedPx=\(uncappedWidth)x\(uncappedHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "changed=\(sizeChanged ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else {
            ghostty_surface_refresh(surface)
            return false
        }
        ghostty_surface_set_size(surface, uncappedWidth, uncappedHeight)
        lastPixelWidth = uncappedWidth
        lastPixelHeight = uncappedHeight
        ghostty_surface_refresh(surface)
        return true
    }

    private func cappedByMobileViewportLimit(
        width: UInt32,
        height: UInt32,
        surface: ghostty_surface_t
    ) -> (width: UInt32, height: UInt32) {
        guard let mobileViewportPixelLimit = mobileViewportPixelLimit(for: surface) else {
            return (width, height)
        }
        return (
            width: min(width, mobileViewportPixelLimit.width),
            height: min(height, mobileViewportPixelLimit.height)
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

    /// Force a full size recalculation and surface redraw.
    @MainActor
    public func forceRefresh(reason: String = "unspecified") {
#if DEBUG
        let hasSurface = surface != nil
        let viewState: String
        if let view = attachedView {
            let inWindow = uiWindow != nil
            let bounds = view.bounds
            let metalOK = (view.layer as? CAMetalLayer) != nil
            viewState = "inWindow=\(inWindow) bounds=\(bounds) metalOK=\(metalOK) hasSurface=\(hasSurface)"
        } else {
            viewState = "NO_ATTACHED_VIEW hasSurface=\(hasSurface)"
        }
        logDebugEvent("forceRefresh: \(id) reason=\(reason) \(viewState)")
#endif
        guard let view = attachedView,
              let window = uiWindow,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }
#if DEBUG
        recordDebugForceRefresh()
#endif
        // Re-read self.surface before each ghostty call to guard against the surface
        // being freed during wake-from-sleep geometry reconciliation (issue #432).
        // The surface can be invalidated between calls when AppKit layout triggers
        // view lifecycle changes (e.g., forceRefreshSurface → layout → deinit → free).

        // Reassert display id on topology churn (split close/reparent) before forcing a refresh.
        // This avoids a first-run stuck-vsync state where Ghostty believes vsync is active
        // but callbacks have not resumed for the current display.
        let displayID = (window.screen ?? NSScreen.main)?.displayID
#if DEBUG
        let accessReason = "forceRefresh.\(reason)"
#else
        let accessReason = "forceRefresh"
#endif
        guard let currentSurface = liveSurfaceForGhosttyAccess(reason: accessReason) else {
            return
        }
        if let displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(currentSurface, displayID)
        }

        view.forceRefreshSurface()
#if DEBUG
        let refreshReason = "forceRefresh.refresh.\(reason)"
#else
        let refreshReason = "forceRefresh.refresh"
#endif
        guard let surface = liveSurfaceForGhosttyAccess(reason: refreshReason) else {
            return
        }
        ghostty_surface_refresh(surface)
    }
}
