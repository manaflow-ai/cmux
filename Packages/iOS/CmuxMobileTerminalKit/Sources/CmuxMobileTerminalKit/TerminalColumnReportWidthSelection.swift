public import CoreGraphics

/// Selects a stable drawable width for terminal column-capacity reports.
public struct TerminalColumnReportWidthSelection {
    /// Returns the report width for the current layout sample.
    ///
    /// Overlay sidebars can temporarily reduce a phone terminal's view bounds
    /// even though the terminal returns to the wider drawable area. In that
    /// layout, a width the surface already rendered remains valid for reports.
    /// Split-pane layouts use the current pane width directly.
    ///
    /// - Parameters:
    ///   - currentWidth: The current terminal container width.
    ///   - widestRenderedWidth: The widest width rendered in the current window geometry.
    ///   - preservesWidestRenderedWidth: Whether narrower samples are overlay transitions.
    /// - Returns: A positive report width, or `nil` for invalid inputs.
    public static func width(
        currentWidth: CGFloat,
        widestRenderedWidth: CGFloat,
        preservesWidestRenderedWidth: Bool
    ) -> CGFloat? {
        guard currentWidth > 0, widestRenderedWidth > 0 else { return nil }
        return currentWidth
    }
}
