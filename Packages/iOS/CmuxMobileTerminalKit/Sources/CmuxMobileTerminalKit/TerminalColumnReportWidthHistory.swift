public import CoreGraphics

/// Tracks drawable widths across overlay transitions and window resizing.
public struct TerminalColumnReportWidthHistory {
    private var windowSize: CGSize = .zero
    private var widestWidth: CGFloat = 0
    private var wasCompactLayout: Bool?

    /// Creates an empty width history for one terminal surface.
    public init() {}

    /// Selects the width to report for the current layout sample.
    /// - Parameters:
    ///   - currentWidth: Current drawable width in points.
    ///   - windowSize: Current containing window size in points.
    ///   - isCompactLayout: Whether navigation uses a compact overlay layout.
    /// - Returns: The drawable width, preserving overlay widths only in compact layouts.
    public mutating func width(
        currentWidth: CGFloat,
        windowSize: CGSize,
        isCompactLayout: Bool
    ) -> CGFloat {
        if abs(windowSize.width - self.windowSize.width) > 1
            || abs(windowSize.height - self.windowSize.height) > 1
            || wasCompactLayout != isCompactLayout {
            self.windowSize = windowSize
            widestWidth = currentWidth
            wasCompactLayout = isCompactLayout
        } else {
            widestWidth = max(widestWidth, currentWidth)
        }
        return TerminalColumnReportWidthSelection(
            currentWidth: currentWidth,
            widestRenderedWidth: widestWidth,
            preservesWidestRenderedWidth: true
        ).width ?? currentWidth
    }
}
