import Foundation

/// Snaps dragged and resized pane frames to neighbor edges and to the
/// canonical gap.
///
/// Snap targets, in priority order on equal distance: edge alignment with a
/// neighbor (left-left, right-right, top-top, bottom-bottom), gap adjacency
/// (this pane's edge exactly ``CanvasMetrics/gap`` away from a neighbor's
/// opposing edge), and center alignment. The two axes snap independently.
///
/// ```swift
/// let engine = CanvasSnapEngine(metrics: metrics)
/// let result = engine.snapForMove(proposed: dragged, neighbors: layout.frames(excluding: id))
/// // result.frame is the rect to apply, result.guides are the lines to draw.
/// ```
public struct CanvasSnapEngine: Sendable {
    /// The metrics supplying the gap and snap threshold.
    public let metrics: CanvasMetrics

    /// Creates a snap engine.
    ///
    /// - Parameter metrics: The metrics supplying the gap and snap threshold.
    public init(metrics: CanvasMetrics) {
        self.metrics = metrics
    }

    /// One snap candidate on a single axis.
    private struct Candidate {
        /// Distance the proposed frame must move along the axis to snap.
        let delta: Double
        /// Where the rendered guide line sits after snapping.
        let guidePosition: Double
        /// Lower numbers win ties at equal distance.
        let priority: Int
        /// The neighbor that produced the candidate, for guide span computation.
        let neighbor: CanvasRect
    }

    /// Snaps a frame being moved (both edges of each axis translate together).
    ///
    /// - Parameters:
    ///   - proposed: The frame implied by the raw drag delta.
    ///   - neighbors: Frames of every other pane on the canvas.
    /// - Returns: The snapped frame plus any active guides. When no candidate
    ///   is within ``CanvasMetrics/snapThreshold``, the proposed frame is
    ///   returned unchanged with no guides.
    public func snapForMove(proposed: CanvasRect, neighbors: [CanvasRect]) -> CanvasSnapResult {
        var frame = proposed
        var guides: [CanvasGuide] = []

        if let best = bestCandidate(moveCandidatesX(for: proposed, neighbors: neighbors)) {
            frame.x += best.delta
            guides.append(verticalGuide(at: best.guidePosition, snapped: frame, neighbor: best.neighbor))
        }
        if let best = bestCandidate(moveCandidatesY(for: proposed, neighbors: neighbors)) {
            frame.y += best.delta
            guides.append(horizontalGuide(at: best.guidePosition, snapped: frame, neighbor: best.neighbor))
        }
        return CanvasSnapResult(frame: frame, guides: guides)
    }

    /// Snaps and clamps a frame being resized.
    ///
    /// Only the edges named in `edges` move; opposite edges stay fixed. After
    /// snapping, the frame is clamped to ``CanvasMetrics/minPaneSize`` by
    /// moving the dragged edge back; a snap undone by clamping drops its guide.
    ///
    /// - Parameters:
    ///   - proposed: The frame implied by the raw resize delta.
    ///   - edges: The edges the gesture is moving.
    ///   - neighbors: Frames of every other pane on the canvas.
    /// - Returns: The snapped, min-size-clamped frame plus any active guides.
    public func snapForResize(
        proposed: CanvasRect,
        edges: CanvasResizeEdges,
        neighbors: [CanvasRect]
    ) -> CanvasSnapResult {
        var frame = proposed
        var guides: [CanvasGuide] = []

        if edges.contains(.left) {
            if let best = bestCandidate(edgeCandidates(
                edge: proposed.minX,
                alignTargets: neighbors.map { ($0.minX, $0) },
                gapTargets: neighbors.map { ($0.maxX + metrics.gap, $0) }
            )) {
                frame.x = proposed.minX + best.delta
                frame.width = proposed.maxX - frame.x
                guides.append(verticalGuide(at: best.guidePosition, snapped: frame, neighbor: best.neighbor))
            }
            if frame.width < metrics.minPaneSize.width {
                frame.x = frame.maxX - metrics.minPaneSize.width
                frame.width = metrics.minPaneSize.width
                guides.removeAll(where: { $0.axis == .vertical })
            }
        } else if edges.contains(.right) {
            if let best = bestCandidate(edgeCandidates(
                edge: proposed.maxX,
                alignTargets: neighbors.map { ($0.maxX, $0) },
                gapTargets: neighbors.map { ($0.minX - metrics.gap, $0) }
            )) {
                frame.width = proposed.maxX + best.delta - frame.x
                guides.append(verticalGuide(at: best.guidePosition, snapped: frame, neighbor: best.neighbor))
            }
            if frame.width < metrics.minPaneSize.width {
                frame.width = metrics.minPaneSize.width
                guides.removeAll(where: { $0.axis == .vertical })
            }
        }

        if edges.contains(.top) {
            if let best = bestCandidate(edgeCandidates(
                edge: proposed.minY,
                alignTargets: neighbors.map { ($0.minY, $0) },
                gapTargets: neighbors.map { ($0.maxY + metrics.gap, $0) }
            )) {
                frame.y = proposed.minY + best.delta
                frame.height = proposed.maxY - frame.y
                guides.append(horizontalGuide(at: best.guidePosition, snapped: frame, neighbor: best.neighbor))
            }
            if frame.height < metrics.minPaneSize.height {
                frame.y = frame.maxY - metrics.minPaneSize.height
                frame.height = metrics.minPaneSize.height
                guides.removeAll(where: { $0.axis == .horizontal })
            }
        } else if edges.contains(.bottom) {
            if let best = bestCandidate(edgeCandidates(
                edge: proposed.maxY,
                alignTargets: neighbors.map { ($0.maxY, $0) },
                gapTargets: neighbors.map { ($0.minY - metrics.gap, $0) }
            )) {
                frame.height = proposed.maxY + best.delta - frame.y
                guides.append(horizontalGuide(at: best.guidePosition, snapped: frame, neighbor: best.neighbor))
            }
            if frame.height < metrics.minPaneSize.height {
                frame.height = metrics.minPaneSize.height
                guides.removeAll(where: { $0.axis == .horizontal })
            }
        }

        return CanvasSnapResult(frame: frame, guides: guides)
    }

    private func bestCandidate(_ candidates: [Candidate]) -> Candidate? {
        candidates
            .filter { abs($0.delta) <= metrics.snapThreshold }
            .min(by: { lhs, rhs in
                if abs(lhs.delta) != abs(rhs.delta) { return abs(lhs.delta) < abs(rhs.delta) }
                return lhs.priority < rhs.priority
            })
    }

    private func moveCandidatesX(for rect: CanvasRect, neighbors: [CanvasRect]) -> [Candidate] {
        var candidates: [Candidate] = []
        candidates.reserveCapacity(neighbors.count * 5)
        for neighbor in neighbors {
            candidates.append(Candidate(
                delta: neighbor.minX - rect.minX, guidePosition: neighbor.minX,
                priority: 0, neighbor: neighbor
            ))
            candidates.append(Candidate(
                delta: neighbor.maxX - rect.maxX, guidePosition: neighbor.maxX,
                priority: 0, neighbor: neighbor
            ))
            candidates.append(Candidate(
                delta: neighbor.maxX + metrics.gap - rect.minX, guidePosition: neighbor.maxX + metrics.gap,
                priority: 1, neighbor: neighbor
            ))
            candidates.append(Candidate(
                delta: neighbor.minX - metrics.gap - rect.maxX, guidePosition: neighbor.minX - metrics.gap,
                priority: 1, neighbor: neighbor
            ))
            candidates.append(Candidate(
                delta: neighbor.midX - rect.midX, guidePosition: neighbor.midX,
                priority: 2, neighbor: neighbor
            ))
        }
        return candidates
    }

    private func moveCandidatesY(for rect: CanvasRect, neighbors: [CanvasRect]) -> [Candidate] {
        var candidates: [Candidate] = []
        candidates.reserveCapacity(neighbors.count * 5)
        for neighbor in neighbors {
            candidates.append(Candidate(
                delta: neighbor.minY - rect.minY, guidePosition: neighbor.minY,
                priority: 0, neighbor: neighbor
            ))
            candidates.append(Candidate(
                delta: neighbor.maxY - rect.maxY, guidePosition: neighbor.maxY,
                priority: 0, neighbor: neighbor
            ))
            candidates.append(Candidate(
                delta: neighbor.maxY + metrics.gap - rect.minY, guidePosition: neighbor.maxY + metrics.gap,
                priority: 1, neighbor: neighbor
            ))
            candidates.append(Candidate(
                delta: neighbor.minY - metrics.gap - rect.maxY, guidePosition: neighbor.minY - metrics.gap,
                priority: 1, neighbor: neighbor
            ))
            candidates.append(Candidate(
                delta: neighbor.midY - rect.midY, guidePosition: neighbor.midY,
                priority: 2, neighbor: neighbor
            ))
        }
        return candidates
    }

    private func edgeCandidates(
        edge: Double,
        alignTargets: [(Double, CanvasRect)],
        gapTargets: [(Double, CanvasRect)]
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        candidates.reserveCapacity(alignTargets.count + gapTargets.count)
        for (target, neighbor) in alignTargets {
            candidates.append(Candidate(
                delta: target - edge, guidePosition: target, priority: 0, neighbor: neighbor
            ))
        }
        for (target, neighbor) in gapTargets {
            candidates.append(Candidate(
                delta: target - edge, guidePosition: target, priority: 1, neighbor: neighbor
            ))
        }
        return candidates
    }

    private func verticalGuide(at position: Double, snapped: CanvasRect, neighbor: CanvasRect) -> CanvasGuide {
        let lower = min(snapped.minY, neighbor.minY)
        let upper = max(snapped.maxY, neighbor.maxY)
        return CanvasGuide(axis: .vertical, position: position, span: lower...max(lower, upper))
    }

    private func horizontalGuide(at position: Double, snapped: CanvasRect, neighbor: CanvasRect) -> CanvasGuide {
        let lower = min(snapped.minX, neighbor.minX)
        let upper = max(snapped.maxX, neighbor.maxX)
        return CanvasGuide(axis: .horizontal, position: position, span: lower...max(lower, upper))
    }
}
