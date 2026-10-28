public import CoreGraphics

/// Where a pane's vertical tab column, its buttons and its content go (`tabs.barPosition` left or
/// right; a prototype, user 2026-10-27): the column on that edge at full height, at most half the
/// pane wide; the pane's buttons over the column's top row; the content beside it at full height.
/// Rects are in the pane's flipped coordinates.
public struct VerticalTabsLayout: Equatable, Sendable {
    /// The tab column.
    public var column: CGRect
    /// The pane's buttons, over the column's top row (empty when the pane has none).
    public var tools: CGRect
    /// The content beside the column.
    public var content: CGRect

    /// - Parameters:
    ///   - bounds: The pane's bounds.
    ///   - onLeft: The column on the left edge, else the right.
    ///   - toolsWidth: The buttons' natural width (0: no buttons).
    ///   - rowHeight: The height of the buttons' row (the pane's strip height).
    ///   - columnWidth: The column's preferred width.
    public init(bounds: CGRect, onLeft: Bool, toolsWidth: CGFloat, rowHeight: CGFloat,
                columnWidth: CGFloat = VerticalTabListView.preferredWidth) {
        let width = min(columnWidth, (bounds.width / 2).rounded(.down))
        column = CGRect(x: onLeft ? 0 : bounds.width - width, y: 0, width: width, height: bounds.height)
        let tools = min(toolsWidth, width)
        self.tools = tools > 0 ? CGRect(x: column.maxX - tools, y: 0, width: tools, height: rowHeight) : .zero
        content = CGRect(x: onLeft ? width : 0, y: 0, width: bounds.width - width, height: bounds.height)
    }
}
