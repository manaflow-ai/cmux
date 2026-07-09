public import AppKit
public import Foundation
public import GhosttyKit

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

    func cappedByMobileViewportLimit(
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

    private func cellCount(pixelDimension: UInt32, cellSize: Int, nonGridPixels: Int) -> Int {
        let gridPixels = max(0, Int(pixelDimension) - max(0, nonGridPixels))
        return max(1, gridPixels / max(1, cellSize))
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
