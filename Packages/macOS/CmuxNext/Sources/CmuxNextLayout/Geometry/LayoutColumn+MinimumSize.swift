public import CoreGraphics

nonisolated extension LayoutColumn {
    /// The smallest frame this column gets while its screen has room: its panes' minimum
    /// (``SplitGeometry/minimumSize(of:style:)``), widened for a docked agent chat to
    /// ``LayoutStyle/minimumAgentChatContentWidth``. Geometry and divider drags both read it, so
    /// a drag can never leave a column narrower than the layout would place it.
    ///
    /// - Parameter style: The layout knobs that hold the minimums.
    /// - Returns: The minimum width and height in points.
    public func minimumSize(style: LayoutStyle) -> CGSize {
        var size = SplitGeometry.minimumSize(of: root, style: style)
        if dock?.role == .agentChat {
            size.width = max(size.width, style.minimumAgentChatContentWidth + style.panePadding * 2)
        }
        return size
    }
}
