/// A command that arranges every pane of a canvas (classic `CanvasAlignmentCommand`).
public nonisolated enum CanvasArrangement: String, Hashable, Sendable, CaseIterable {
    /// Every pane's left edge to the leftmost one.
    case alignLeft
    /// Every pane's right edge to the rightmost one.
    case alignRight
    /// Every pane's top edge to the topmost one.
    case alignTop
    /// Every pane's bottom edge to the bottommost one.
    case alignBottom
    /// Every pane takes the reference pane's width; left edges stay.
    case equalizeWidths
    /// Every pane takes the reference pane's height; top edges stay.
    case equalizeHeights
    /// Panes packed left to right at the canvas gap, in their order; vertical places stay.
    case distributeHorizontally
    /// Panes packed top to bottom at the canvas gap, in their order; horizontal places stay.
    case distributeVertically
    /// Panes in rows by their vertical center, each row packed left to right at
    /// the canvas gap, rows stacked at the gap; sizes and order stay.
    case tidy
}
