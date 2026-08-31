public import CoreGraphics

/// Fixed geometry for the sidebar filter chrome, scaled by the sidebar's own
/// font scale so the field tracks the row text it sits above.
///
/// Values are pinned to the existing workspace row so the field reads as part
/// of the same list rather than a control bolted on top: the same 8pt leading
/// inset, the same 6pt corner radius as a selected row.
public struct SidebarFilterMetrics: Sendable, Equatable {
    /// Multiplier applied to every font size, matching the row's font scale.
    public let fontScale: CGFloat

    /// Creates metrics for a given sidebar font scale.
    ///
    /// - Parameter fontScale: The sidebar's current font scale, where 1 is the
    ///   default size.
    public init(fontScale: CGFloat = 1) {
        self.fontScale = fontScale
    }

    /// Horizontal inset matching the workspace row's leading edge.
    public var horizontalInset: CGFloat { 8 }
    /// Corner radius matching a selected workspace row.
    public var cornerRadius: CGFloat { 6 }
    /// Height of the field.
    public var fieldHeight: CGFloat { max(22, 26 * fontScale) }
    /// Padding inside the field.
    public var fieldPadding: CGFloat { 7 }
    /// Spacing between the icon, text, and trailing controls.
    public var itemSpacing: CGFloat { 6 }
    /// Point size of the query text.
    public var queryFontSize: CGFloat { 11.5 * fontScale }
    /// Point size of the leading glyph and trailing count.
    public var accessoryFontSize: CGFloat { 10.5 * fontScale }
    /// Point size of the scope chip.
    public var scopeFontSize: CGFloat { 9.5 * fontScale }
}
