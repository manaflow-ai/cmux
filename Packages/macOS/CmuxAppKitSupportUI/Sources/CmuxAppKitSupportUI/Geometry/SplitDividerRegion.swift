public import AppKit

/// A single split-view divider's hit region, expressed in window coordinates so
/// callers can map it into any hosting view's space when installing cursor rects.
public struct SplitDividerRegion: Equatable {
    /// The divider rectangle in the window's coordinate space.
    public let rectInWindow: NSRect
    /// Whether the divider belongs to a vertical split (left/right resize).
    public let isVertical: Bool

    public init(rectInWindow: NSRect, isVertical: Bool) {
        self.rectInWindow = rectInWindow
        self.isVertical = isVertical
    }
}
