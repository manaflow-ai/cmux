public import CoreGraphics

/// `sidebar.border` and `sidebar.borderWidth` in cmux-next.json (R93): a
/// line on the sidebar's trailing edge. Off by default: the sidebar sits on
/// the window's one backdrop with no seam, and its edge shows a line only
/// while hovered or dragged (plans/cmux-next/windows.md).
public nonisolated struct SidebarBorder: Hashable, Sendable {
    /// The line stays at rest.
    public var shows: Bool
    /// Width in points; nil is the divider hairline (`Metrics.dividerThickness`).
    public var width: CGFloat?

    public init(shows: Bool = false, width: CGFloat? = nil) {
        self.shows = shows
        self.width = width
    }

    public static let widthRange: ClosedRange<CGFloat> = 0.5...4
}
