import Foundation

/// Answers "which pane is to the left/right/above/below the focused pane".
///
/// Candidates must lie in the directional half-plane (their center past the
/// focused pane's center along the movement axis). Among candidates, panes
/// whose orthogonal extent overlaps the focused pane are strongly preferred;
/// the score is the axis distance plus a weighted orthogonal misalignment.
/// Ties break deterministically by pane identifier.
public struct CanvasSpatialNavigator: Sendable {
    /// Orthogonal misalignment weight for candidates overlapping the focused
    /// pane's orthogonal extent.
    private static let overlappingWeight = 0.25
    /// Orthogonal misalignment weight for non-overlapping candidates.
    private static let nonOverlappingWeight = 3.0

    /// Creates a navigator.
    public init() {}

    /// Finds the nearest pane in a direction.
    ///
    /// - Parameters:
    ///   - direction: The movement direction.
    ///   - from: The currently focused pane.
    ///   - layout: The canvas layout to search.
    /// - Returns: The pane to focus next, or `nil` when no pane lies in that
    ///   direction (or `from` is not on the canvas).
    public func pane(
        _ direction: CanvasDirection,
        from: CanvasPaneID,
        in layout: CanvasLayout
    ) -> CanvasPaneID? {
        guard let origin = layout.frame(of: from) else { return nil }

        var best: (id: CanvasPaneID, score: Double)?
        for pane in layout.panes where pane.id != from {
            guard let score = score(of: pane.frame, from: origin, direction: direction) else { continue }
            if let current = best {
                if score < current.score || (score == current.score && pane.id < current.id) {
                    best = (pane.id, score)
                }
            } else {
                best = (pane.id, score)
            }
        }
        return best?.id
    }

    private func score(
        of candidate: CanvasRect,
        from origin: CanvasRect,
        direction: CanvasDirection
    ) -> Double? {
        let axisDistance: Double
        let orthogonalDistance: Double
        let overlaps: Bool

        switch direction {
        case .left, .right:
            axisDistance = direction == .right
                ? candidate.midX - origin.midX
                : origin.midX - candidate.midX
            orthogonalDistance = abs(candidate.midY - origin.midY)
            overlaps = candidate.minY < origin.maxY && origin.minY < candidate.maxY
        case .up, .down:
            axisDistance = direction == .down
                ? candidate.midY - origin.midY
                : origin.midY - candidate.midY
            orthogonalDistance = abs(candidate.midX - origin.midX)
            overlaps = candidate.minX < origin.maxX && origin.minX < candidate.maxX
        }

        guard axisDistance > 0.5 else { return nil }
        let weight = overlaps ? Self.overlappingWeight : Self.nonOverlappingWeight
        return axisDistance + weight * orthogonalDistance
    }
}
