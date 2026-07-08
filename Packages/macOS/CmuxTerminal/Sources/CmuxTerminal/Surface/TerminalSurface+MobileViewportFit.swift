public import AppKit
internal import CmuxTerminalCore
public import Foundation
public import GhosttyKit

// MARK: - Mobile viewport fitting

struct MobileViewportFitResult {
    let width: UInt32
    let height: UInt32
    let columns: Int
    let rows: Int
    let grantWidth: UInt32
    let grantHeight: UInt32
    let baseFont: Float
    let currentFont: Float
    let fontChanged: Bool

    static func passthrough(width: UInt32, height: UInt32) -> Self {
        .init(width: width, height: height, columns: 0, rows: 0, grantWidth: width, grantHeight: height, baseFont: 0, currentFont: 0, fontChanged: false)
    }

    static func passthrough(width: UInt32, height: UInt32, grantWidth: UInt32, grantHeight: UInt32) -> Self {
        .init(width: width, height: height, columns: 0, rows: 0, grantWidth: grantWidth, grantHeight: grantHeight, baseFont: 0, currentFont: 0, fontChanged: false)
    }

    static func grant(
        _ box: (width: UInt32, height: UInt32),
        columns: Int,
        rows: Int,
        baseFont: Float,
        currentFont: Float,
        fontChanged: Bool
    ) -> Self {
        .init(width: box.width, height: box.height, columns: columns, rows: rows, grantWidth: box.width, grantHeight: box.height, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
    }

    static func fallback(
        width: UInt32,
        height: UInt32,
        columns: Int,
        rows: Int,
        grant: (width: UInt32, height: UInt32),
        baseFont: Float,
        currentFont: Float,
        fontChanged: Bool
    ) -> Self {
        .init(width: width, height: height, columns: columns, rows: rows, grantWidth: grant.width, grantHeight: grant.height, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
    }
}

extension TerminalSurface {
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
            return legacyApplyMobileViewportLimit(surface: surface, columns: columns, rows: rows, reason: reason)
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
        let targetWidth = safePixelDimension(cellCount: columns, cellSize: cellWidth, nonGridPixels: horizontalNonGridPixels)
        let targetHeight = safePixelDimension(cellCount: rows, cellSize: cellHeight, nonGridPixels: verticalNonGridPixels)

        mobileViewportCellLimit = (columns: max(1, columns), rows: max(1, rows))
        let baseWidth = lastUncappedPixelWidth > 0 ? lastUncappedPixelWidth : targetWidth
        let baseHeight = lastUncappedPixelHeight > 0 ? lastUncappedPixelHeight : targetHeight
        let appliedWidth = min(targetWidth, baseWidth)
        let appliedHeight = min(targetHeight, baseHeight)
        let sizeChanged = appliedWidth != lastPixelWidth || appliedHeight != lastPixelHeight
        let appliedColumns = cellCount(pixelDimension: appliedWidth, cellSize: cellWidth, nonGridPixels: horizontalNonGridPixels)
        let appliedRows = cellCount(pixelDimension: appliedHeight, cellSize: cellHeight, nonGridPixels: verticalNonGridPixels)
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
    func mobileViewportFittedSize(
        width: UInt32,
        height: UInt32,
        surface: ghostty_surface_t,
        reason: String
    ) -> MobileViewportFitResult {
        guard width > 0, height > 0 else { return .passthrough(width: width, height: height) }
        guard let mobileViewportCellLimit else { return .passthrough(width: width, height: height) }
        if manualIO {
            guard let limit = mobileViewportPixelLimit(for: surface) else { return .passthrough(width: width, height: height) }
            return .passthrough(width: min(width, limit.width), height: min(height, limit.height), grantWidth: limit.width, grantHeight: limit.height)
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
        var geometry = mobileViewportGeometry(paneWidth: paneWidth, paneHeight: paneHeight, measurement: measurement)
        var targetFont = geometry.integerCellTargetFontPointSize(
            baseFontPointSize: baseFont,
            currentFontPointSize: currentFont,
            columns: grantedColumns,
            rows: grantedRows
        )
        var fontChanged = false
        var appliedBox = geometry.grantPixelBox(columns: grantedColumns, rows: grantedRows)

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
                    geometry = mobileViewportGeometry(paneWidth: paneWidth, paneHeight: paneHeight, measurement: measurement)
                }
            }

            appliedBox = geometry.grantPixelBox(columns: grantedColumns, rows: grantedRows)
            if !geometry.needsRefinement(grantWidthPx: appliedBox.width, grantHeightPx: appliedBox.height) {
                return .grant(appliedBox, columns: grantedColumns, rows: grantedRows, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
            }

            guard currentFont > fontFloor + 0.001 else {
                break
            }

            let nextTarget = geometry.correctiveFontPointSizeForOverflow(
                currentFontPointSize: currentFont,
                columns: grantedColumns,
                rows: grantedRows
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
                geometry = mobileViewportGeometry(paneWidth: paneWidth, paneHeight: paneHeight, measurement: measurement)
                targetFont = nextTarget
            } else {
                break
            }
        }

        appliedBox = geometry.grantPixelBox(columns: grantedColumns, rows: grantedRows)
        if !geometry.needsRefinement(grantWidthPx: appliedBox.width, grantHeightPx: appliedBox.height) {
            return .grant(appliedBox, columns: grantedColumns, rows: grantedRows, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
        }

        let fontFloor = min(baseFont, MobileViewportFitGeometry.defaultFontFloorPointSize)
        if currentFont > fontFloor + 0.001 {
            guard applyMobileViewportFontPointSize(fontFloor) else {
                let fallback = geometry.cappedFallbackGrant(grantedColumns: grantedColumns, grantedRows: grantedRows)
                return .fallback(width: fallback.width, height: fallback.height, columns: fallback.columns, rows: fallback.rows, grant: appliedBox, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
            }
            mobileFittedFontPointSize = fontFloor
            currentFont = fontFloor
            fontChanged = true
            measurement = mobileViewportMeasurement(surface: surface)
            geometry = mobileViewportGeometry(paneWidth: paneWidth, paneHeight: paneHeight, measurement: measurement)
        }
        appliedBox = geometry.grantPixelBox(columns: grantedColumns, rows: grantedRows)
        if !geometry.needsRefinement(grantWidthPx: appliedBox.width, grantHeightPx: appliedBox.height) {
            return .grant(appliedBox, columns: grantedColumns, rows: grantedRows, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
        }

        let fallback = geometry.cappedFallbackGrant(grantedColumns: grantedColumns, grantedRows: grantedRows)
        return .fallback(width: fallback.width, height: fallback.height, columns: fallback.columns, rows: fallback.rows, grant: appliedBox, baseFont: baseFont, currentFont: currentFont, fontChanged: fontChanged)
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
            width: safePixelDimension(cellCount: mobileViewportCellLimit.columns, cellSize: cellWidth, nonGridPixels: horizontalNonGridPixels),
            height: safePixelDimension(cellCount: mobileViewportCellLimit.rows, cellSize: cellHeight, nonGridPixels: verticalNonGridPixels)
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

    private func mobileViewportGeometry(
        paneWidth: Int,
        paneHeight: Int,
        measurement: (
            cellWidth: Int,
            cellHeight: Int,
            horizontalNonGridPixels: Int,
            verticalNonGridPixels: Int
        )
    ) -> MobileViewportFitGeometry {
        MobileViewportFitGeometry(
            paneWidthPx: paneWidth,
            paneHeightPx: paneHeight,
            cellWidthPx: Double(measurement.cellWidth),
            cellHeightPx: Double(measurement.cellHeight),
            horizontalNonGridPixels: measurement.horizontalNonGridPixels,
            verticalNonGridPixels: measurement.verticalNonGridPixels
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

    @MainActor
    func updateMobileViewportBorder(
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
