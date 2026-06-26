public import AppKit

/// The expanded, clipped cursor rect for one split-view divider region, computed
/// in a portal host view's coordinate space.
///
/// A portal host installs resize cursor rects over the split dividers that sit
/// beneath it. The host owns the window->host coordinate conversion and supplies
/// the divider rect already mapped into its own bounds space; this value expands
/// that rect by `expansion` on the divider's resize axis (horizontal for a
/// vertical/left-right divider, vertical for a horizontal/up-down divider), clips
/// it to the host bounds, and carries the matching resize cursor. A `nil`
/// `init?` result means the region produced no drawable rect (degenerate after
/// clipping) and should be skipped.
public struct PortalDividerCursorRect: Equatable {
    /// The expanded divider rect clipped to the host bounds, in host coordinates.
    public let rect: NSRect
    /// The divider orientation, which selects the resize cursor.
    public let cursorKind: SplitDividerCursorKind

    /// Compute the candidate cursor rect for one divider region.
    /// - Parameters:
    ///   - rectInHost: The divider rect already converted into the host view's
    ///     coordinate space.
    ///   - isVertical: Whether the divider belongs to a vertical (left/right) split.
    ///   - hostBounds: The host view's bounds, used to clip the expanded rect.
    ///   - expansion: How far to inset (outward) the rect on the resize axis.
    /// - Returns: `nil` when the clipped rect is null or non-positive in size.
    public init?(rectInHost: NSRect, isVertical: Bool, hostBounds: NSRect, expansion: CGFloat) {
        let expanded = rectInHost.insetBy(
            dx: isVertical ? -expansion : 0,
            dy: isVertical ? 0 : -expansion
        )
        let clipped = expanded.intersection(hostBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        self.rect = clipped
        self.cursorKind = isVertical ? .vertical : .horizontal
    }

    /// The resize cursor matching this candidate's divider orientation.
    public var cursor: NSCursor { cursorKind.cursor }
}
