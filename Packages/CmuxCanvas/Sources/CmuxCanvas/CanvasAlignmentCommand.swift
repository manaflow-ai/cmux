import Foundation

/// An explicit alignment or distribution command applied to a set of panes.
///
/// Commands are executed by ``CanvasAligner``; the gap used by distribution
/// and tidying is always the canonical ``CanvasMetrics/gap``.
public enum CanvasAlignmentCommand: String, Hashable, Codable, Sendable, CaseIterable {
    /// Align every pane's left edge to the leftmost selected edge.
    case alignLeft = "align-left"
    /// Align every pane's right edge to the rightmost selected edge.
    case alignRight = "align-right"
    /// Align every pane's top edge to the topmost selected edge.
    case alignTop = "align-top"
    /// Align every pane's bottom edge to the bottommost selected edge.
    case alignBottom = "align-bottom"
    /// Give every pane the reference pane's width, keeping left edges fixed.
    case equalizeWidths = "equalize-widths"
    /// Give every pane the reference pane's height, keeping top edges fixed.
    case equalizeHeights = "equalize-heights"
    /// Pack panes left-to-right at the canonical gap, keeping vertical positions.
    case distributeHorizontally = "distribute-horizontally"
    /// Pack panes top-to-bottom at the canonical gap, keeping horizontal positions.
    case distributeVertically = "distribute-vertically"
    /// Re-pack panes into clean rows at the canonical gap, preserving sizes
    /// and spatial order — one command from messy canvas to tidy grid.
    case tidy = "tidy"
}
