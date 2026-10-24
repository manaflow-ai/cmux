public import CoreGraphics

/// The find pill's geometry, shared by the native ``FindPillView`` and its web twin
/// (`webviews/src/ui/findPill.css`, whose custom properties carry the same numbers), so a find
/// bar is the same size and in the same place over a terminal, a page, a chat or a diff.
public struct FindPillMetrics {
    public init() {}
    /// The capsule's height; its corner radius is half of it.
    public static let height: CGFloat = 34
    /// The gap between the pill and the pane's top and trailing edges.
    public static let inset: CGFloat = 10
    /// Each round button's side (Apple's minimum pointer target).
    public static let buttonSize: CGFloat = 24
    /// The field's preferred width; a narrow pane narrows it.
    public static let fieldWidth: CGFloat = 150
    /// The count's minimum width, so "2 of 3" and "12 of 30" keep the buttons still.
    public static let countMinWidth: CGFloat = 52
    /// Space before the magnifier.
    public static let leadingPadding: CGFloat = 12
    /// Space after the close button.
    public static let trailingPadding: CGFloat = 5
    /// The hairline separators' height.
    public static let separatorHeight: CGFloat = 16
}
