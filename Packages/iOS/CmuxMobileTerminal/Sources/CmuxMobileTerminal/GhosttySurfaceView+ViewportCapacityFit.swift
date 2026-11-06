#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import UIKit

@MainActor
extension GhosttySurfaceView {
    /// Preserves compact overlay transitions while regular split panes report
    /// their actual width, including on an unfolded iPhone.
    func columnReportContainerWidth(currentWidth: CGFloat) -> CGFloat {
        columnReportWidthHistory.width(
            currentWidth: currentWidth,
            windowSize: window?.bounds.size ?? bounds.size,
            isCompactLayout: traitCollection.horizontalSizeClass == .compact
                || traitCollection.verticalSizeClass == .compact
        )
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
