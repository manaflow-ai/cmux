public import CoreGraphics

/// Captures the visible bottom edge of a scroll view before its keyboard inset changes.
///
/// Restore with ``restoredOffsetY(contentHeight:boundsHeight:adjustedTopInset:adjustedBottomInset:)``
/// after applying the new inset. This keeps the same bottom content visible while
/// the viewport shrinks or grows, so keyboard transitions clip from the top instead
/// of hiding content under the keyboard.
public struct MobileScrollViewportSnapshot: Equatable, Sendable {
    /// The content-space Y coordinate of the visible viewport's bottom edge.
    public let visibleBottomY: CGFloat

    /// Whether the snapshot was close enough to the content end to stay bottom-pinned.
    public let wasAtBottom: Bool

    /// Captures a scroll viewport before a keyboard-driven bottom inset change.
    ///
    /// - Parameters:
    ///   - contentOffsetY: The scroll view's current vertical content offset.
    ///   - boundsHeight: The scroll view's visible bounds height.
    ///   - adjustedBottomInset: The current adjusted bottom inset.
    ///   - contentHeight: The current content height.
    ///   - atBottomThreshold: Maximum distance from content end that counts as pinned.
    ///   - wasAtBottom: Optional caller-owned bottom state. Pass this when a
    ///     surrounding layout owns part of the visible viewport.
    public init(
        contentOffsetY: CGFloat,
        boundsHeight: CGFloat,
        adjustedBottomInset: CGFloat,
        contentHeight: CGFloat,
        atBottomThreshold: CGFloat,
        wasAtBottom: Bool? = nil
    ) {
        visibleBottomY = contentOffsetY + boundsHeight - adjustedBottomInset
        self.wasAtBottom = wasAtBottom ?? (max(0, contentHeight - visibleBottomY) <= atBottomThreshold)
    }

    /// Returns the offset that preserves this snapshot under a new inset.
    ///
    /// - Parameters:
    ///   - contentHeight: The content height after layout.
    ///   - boundsHeight: The scroll view's visible bounds height after layout.
    ///   - adjustedTopInset: The adjusted top inset after layout.
    ///   - adjustedBottomInset: The adjusted bottom inset after layout.
    /// - Returns: A clamped vertical content offset for the post-layout scroll state.
    public func restoredOffsetY(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        adjustedTopInset: CGFloat,
        adjustedBottomInset: CGFloat
    ) -> CGFloat {
        let targetY = wasAtBottom
            ? contentHeight - boundsHeight + adjustedBottomInset
            : visibleBottomY - boundsHeight + adjustedBottomInset
        return min(
            max(targetY, -adjustedTopInset),
            max(-adjustedTopInset, contentHeight - boundsHeight + adjustedBottomInset)
        )
    }
}
