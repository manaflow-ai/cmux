#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import UIKit

@MainActor
extension GhosttySurfaceView {
    /// Keeps phone overlay-sidebar transitions from replacing a proven
    /// full-width report with a temporary split-column width. iPad panes always
    /// report their current drawable width.
    func columnReportContainerWidth(currentWidth: CGFloat) -> CGFloat {
        let currentWindowSize = window?.bounds.size ?? bounds.size
        if abs(currentWindowSize.width - reportWidthWindowSize.width) > 1 ||
            abs(currentWindowSize.height - reportWidthWindowSize.height) > 1 {
            reportWidthWindowSize = currentWindowSize
            widestRenderedContainerWidth = currentWidth
        } else {
            widestRenderedContainerWidth = max(widestRenderedContainerWidth, currentWidth)
        }
        return TerminalColumnReportWidthSelection(
            currentWidth: currentWidth,
            widestRenderedWidth: widestRenderedContainerWidth,
            preservesWidestRenderedWidth: traitCollection.userInterfaceIdiom == .phone
        ).width ?? currentWidth
    }

    /// The viewport report for the current geometry: base-font row and column
    /// capacity (see `TerminalRowCapacityFit`).
    func capacityReportGrid(
        for natural: TerminalGridSize,
        containerPixelWidth: CGFloat,
        containerPixelHeight: CGFloat,
        cellPixelWidth: CGFloat,
        cellPixelHeight: CGFloat
    ) -> TerminalGridSize {
        guard let fit = TerminalRowCapacityFit(
            containerPixelHeight: containerPixelHeight,
            cellPixelHeight: cellPixelHeight,
            containerPixelWidth: containerPixelWidth,
            cellPixelWidth: cellPixelWidth,
            liveFontSize: liveFontSize
        ), let rows = fit.capacityRows(atBaseFontSize: userBaseFontSize) else { return natural }
        let reportFontSize: Float32
        if let effectiveGrid,
           effectiveGrid.rows < rows,
           let fitted = fit.fitFontSize(forEffectiveRows: effectiveGrid.rows) {
            reportFontSize = min(
                max(fitted, userBaseFontSize),
                MobileTerminalFontPreference.maximumSize
            )
        } else {
            reportFontSize = userBaseFontSize
        }
        guard let columns = fit.capacityColumns(atFontSize: reportFontSize) else { return natural }
        return TerminalGridSize(
            columns: columns,
            rows: rows,
            pixelWidth: natural.pixelWidth,
            pixelHeight: natural.pixelHeight
        )
    }

    /// Re-derive the rendered font from the effective grid. The column report
    /// first requests the capacity at this destination font. The horizontal
    /// limit keeps the live font unchanged until that non-clipping grant lands.
    func autoFitFontToEffectiveRows(
        renderedRows: Int,
        containerPixelWidth: CGFloat,
        containerPixelHeight: CGFloat,
        cellPixelWidth: CGFloat,
        cellPixelHeight: CGFloat
    ) {
        guard pendingFontSize == nil else { return }
        guard let eff = effectiveGrid else {
            if abs(liveFontSize - userBaseFontSize) >= 0.25 {
                MobileDebugLog.anchormux("zoom.autofit.decay live=\(liveFontSize) base=\(userBaseFontSize)")
                applyAbsoluteFontSize(userBaseFontSize)
            }
            return
        }
        guard let fit = TerminalRowCapacityFit(
            containerPixelHeight: containerPixelHeight,
            cellPixelHeight: cellPixelHeight,
            containerPixelWidth: containerPixelWidth,
            cellPixelWidth: cellPixelWidth,
            liveFontSize: liveFontSize
        ), let baseRows = fit.capacityRows(atBaseFontSize: userBaseFontSize),
              let baseColumns = fit.capacityColumns(atBaseFontSize: userBaseFontSize) else { return }
        if eff.cols >= baseColumns && eff.rows >= baseRows {
            if abs(liveFontSize - userBaseFontSize) >= 0.25 {
                MobileDebugLog.anchormux(
                    "zoom.autofit.decay-full eff=\(eff.cols)x\(eff.rows) baseGrid=\(baseColumns)x\(baseRows)"
                )
                applyAbsoluteFontSize(userBaseFontSize)
            }
            return
        }
        guard eff.rows < baseRows else {
            if abs(liveFontSize - userBaseFontSize) >= 0.25 {
                MobileDebugLog.anchormux(
                    "zoom.autofit.decay-rows eff=\(eff.cols)x\(eff.rows) baseGrid=\(baseColumns)x\(baseRows)"
                )
                applyAbsoluteFontSize(userBaseFontSize)
            }
            return
        }
        guard TerminalRowCapacityFit.shouldRefit(renderedRows: renderedRows, effectiveRows: eff.rows),
              let target = fit.fitFontSize(forEffectiveRows: eff.rows) else { return }
        let horizontalLimit = fit.maximumFontSize(
            forEffectiveColumns: eff.cols,
            atBaseFontSize: userBaseFontSize
        )
        let maximum = max(
            userBaseFontSize,
            horizontalLimit ?? MobileTerminalFontPreference.maximumSize
        )
        let clamped = min(
            max(target, userBaseFontSize),
            maximum,
            MobileTerminalFontPreference.maximumSize
        )
        guard abs(clamped - liveFontSize) >= 0.25 else { return }
        MobileDebugLog.anchormux(
            "zoom.autofit eff=\(eff.cols)x\(eff.rows) baseGrid=\(baseColumns)x\(baseRows) rendered=\(renderedRows) font \(liveFontSize)->\(clamped)"
        )
        applyAbsoluteFontSize(clamped)
    }
}
#endif
