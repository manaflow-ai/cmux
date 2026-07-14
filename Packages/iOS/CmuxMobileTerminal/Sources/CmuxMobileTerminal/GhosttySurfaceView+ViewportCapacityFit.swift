#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import UIKit

@MainActor
extension GhosttySurfaceView {
    private func destinationFontSize(
        fit: TerminalRowCapacityFit,
        renderedRows: Int,
        baseRows: Int,
        baseColumns: Int,
        preservesCurrentFit: Bool
    ) -> Float32? {
        guard let effectiveGrid,
              effectiveGrid.rows < baseRows else { return nil }
        let shouldFit = preservesCurrentFit
            ? fit.shouldReportDestinationFont(
                renderedRows: renderedRows,
                effectiveRows: effectiveGrid.rows,
                baseFontSize: userBaseFontSize
            )
            : TerminalRowCapacityFit.shouldRefit(
                renderedRows: renderedRows,
                effectiveRows: effectiveGrid.rows
            )
        guard shouldFit,
              let target = fit.fitFontSize(forEffectiveRows: effectiveGrid.rows) else {
            return nil
        }
        let horizontalLimit: Float32? = effectiveGrid.cols < baseColumns
            ? fit.maximumFontSize(
                forEffectiveColumns: effectiveGrid.cols,
                atBaseFontSize: userBaseFontSize
            )
            : nil
        let maximum = max(
            userBaseFontSize,
            horizontalLimit ?? MobileTerminalFontPreference.maximumSize
        )
        return min(
            max(target, userBaseFontSize),
            maximum,
            MobileTerminalFontPreference.maximumSize
        )
    }

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
        ), let rows = fit.capacityRows(atBaseFontSize: userBaseFontSize),
           let baseColumns = fit.capacityColumns(atBaseFontSize: userBaseFontSize) else {
            return natural
        }
        let destinationFontSize = destinationFontSize(
            fit: fit,
            renderedRows: natural.rows,
            baseRows: rows,
            baseColumns: baseColumns,
            preservesCurrentFit: true
        )
        let reportFontSize = destinationFontSize ?? userBaseFontSize
        guard let columns = fit.capacityColumns(atFontSize: reportFontSize) else { return natural }
        if let destinationFontSize {
            if destinationFontSize > liveFontSize + 0.25,
               let effectiveGrid {
                let request = TerminalViewportFontGrantRequest(
                    fontSize: destinationFontSize,
                    reportColumns: columns,
                    reportRows: rows,
                    sourceEffectiveRows: effectiveGrid.rows
                )
                if viewportFontGrantState.decision(for: request) == .wait(requestNewReport: true) {
                    viewportFontGrantNeedsReport = true
                }
            } else {
                viewportFontGrantState.cancelPendingRequest()
            }
        } else {
            viewportFontGrantState.reset()
        }
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
            viewportFontGrantState.reset()
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
            viewportFontGrantState.reset()
            if abs(liveFontSize - userBaseFontSize) >= 0.25 {
                MobileDebugLog.anchormux(
                    "zoom.autofit.decay-full eff=\(eff.cols)x\(eff.rows) baseGrid=\(baseColumns)x\(baseRows)"
                )
                applyAbsoluteFontSize(userBaseFontSize)
            }
            return
        }
        guard eff.rows < baseRows else {
            viewportFontGrantState.reset()
            if abs(liveFontSize - userBaseFontSize) >= 0.25 {
                MobileDebugLog.anchormux(
                    "zoom.autofit.decay-rows eff=\(eff.cols)x\(eff.rows) baseGrid=\(baseColumns)x\(baseRows)"
                )
                applyAbsoluteFontSize(userBaseFontSize)
            }
            return
        }
        guard let clamped = destinationFontSize(
            fit: fit,
            renderedRows: renderedRows,
            baseRows: baseRows,
            baseColumns: baseColumns,
            preservesCurrentFit: false
        ) else { return }
        guard abs(clamped - liveFontSize) >= 0.25 else { return }
        if clamped > liveFontSize,
           let reportColumns = fit.capacityColumns(atFontSize: clamped) {
            let request = TerminalViewportFontGrantRequest(
                fontSize: clamped,
                reportColumns: reportColumns,
                reportRows: baseRows,
                sourceEffectiveRows: eff.rows
            )
            switch viewportFontGrantState.decision(for: request) {
            case .wait, .reject:
                return
            }
        } else {
            viewportFontGrantState.reset()
        }
        MobileDebugLog.anchormux(
            "zoom.autofit eff=\(eff.cols)x\(eff.rows) baseGrid=\(baseColumns)x\(baseRows) rendered=\(renderedRows) font \(liveFontSize)->\(clamped)"
        )
        applyAbsoluteFontSize(clamped)
    }
}
#endif
