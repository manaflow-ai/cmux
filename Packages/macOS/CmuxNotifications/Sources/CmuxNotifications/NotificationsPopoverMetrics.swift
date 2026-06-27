public import Foundation

/// Size constraints for the notifications popover (default, minimum, and maximum
/// width/height in points).
public struct NotificationsPopoverMetrics: Sendable {
    /// The default width the popover opens at, in points.
    public let defaultWidth: CGFloat
    /// The default height the popover opens at, in points.
    public let defaultHeight: CGFloat
    /// The smallest width the popover can be resized to, in points.
    public let minWidth: CGFloat
    /// The smallest height the popover can be resized to, in points.
    public let minHeight: CGFloat
    /// The largest width the popover can be resized to, in points.
    public let maxWidth: CGFloat
    /// The largest height the popover can be resized to, in points.
    public let maxHeight: CGFloat

    /// Creates a set of popover size constraints.
    public init(
        defaultWidth: CGFloat,
        defaultHeight: CGFloat,
        minWidth: CGFloat,
        minHeight: CGFloat,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) {
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    /// The standard notifications-popover size constraints used by the app.
    public static let standard = NotificationsPopoverMetrics(
        defaultWidth: 560,
        defaultHeight: 760,
        minWidth: 420,
        minHeight: 320,
        maxWidth: 1000,
        maxHeight: 1200
    )
}
