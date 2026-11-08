public import CoreGraphics

/// Selects a stable drawable width for terminal column-capacity reports.
public struct TerminalColumnReportWidthSelection {
    /// The current terminal container width.
    public let currentWidth: CGFloat
    /// The widest width rendered in the current window geometry.
    public let widestRenderedWidth: CGFloat
    /// Whether narrower samples are overlay transitions.
    public let preservesWidestRenderedWidth: Bool

    /// Creates a selection for one measured layout sample.
    public init(
        currentWidth: CGFloat,
        widestRenderedWidth: CGFloat,
        preservesWidestRenderedWidth: Bool
    ) {
        self.currentWidth = currentWidth
        self.widestRenderedWidth = widestRenderedWidth
        self.preservesWidestRenderedWidth = preservesWidestRenderedWidth
    }

    /// Returns the report width for the current layout sample.
    ///
    /// Overlay sidebars can temporarily reduce a phone terminal's view bounds
    /// even though the terminal returns to the wider drawable area. In that
    /// layout, a width the surface already rendered remains valid for reports.
    /// Split-pane layouts use the current pane width directly.
    ///
    /// - Returns: A positive report width, or `nil` for invalid inputs.
    public var width: CGFloat? {
        guard currentWidth > 0, widestRenderedWidth > 0 else { return nil }
        return preservesWidestRenderedWidth
            ? max(currentWidth, widestRenderedWidth)
            : currentWidth
    }
}
