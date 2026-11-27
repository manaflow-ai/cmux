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
    ///
    /// `measuredFontSize` is the font the surface was rendering at when the
    /// cell size was measured (captured with the geometry pass), NOT the
    /// current `liveFontSize`: a zoom applied between the measurement and
    /// this call would otherwise break the base-font normalization by the
    /// zoom ratio and report a grid several times too small or too large.
    func capacityReportGrid(
        for natural: TerminalGridSize,
        containerPixelWidth: CGFloat,
        containerPixelHeight: CGFloat,
        cellPixelWidth: CGFloat,
        cellPixelHeight: CGFloat,
        measuredFontSize: Float32
    ) -> TerminalGridSize {
        guard let fit = TerminalRowCapacityFit(
            containerPixelHeight: containerPixelHeight,
            cellPixelHeight: cellPixelHeight,
            containerPixelWidth: containerPixelWidth,
            cellPixelWidth: cellPixelWidth,
            liveFontSize: measuredFontSize
        ), let rows = fit.capacityRows(atBaseFontSize: userBaseFontSize),
              let columns = fit.capacityColumns(atBaseFontSize: userBaseFontSize) else { return natural }
        return TerminalGridSize(
            columns: columns,
            rows: rows,
            pixelWidth: natural.pixelWidth,
            pixelHeight: natural.pixelHeight
        )
    }
}
#endif
