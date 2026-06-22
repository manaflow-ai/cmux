import Foundation

/// Chooses where a new pane goes on the canvas.
///
/// Placement never moves existing panes: the placer tries the canonical-gap
/// position to the right of the anchor, then below, left, above, then scans
/// outward, and finally falls back to the area right of all existing content
/// (which is free by construction).
public struct CanvasPlacer: Sendable {
    /// The metrics supplying the canonical gap.
    public let metrics: CanvasMetrics

    /// Bound on the outward scan so placement stays O(existing panes).
    private static let scanColumns = 16
    private static let scanRows = 8

    /// Creates a placer.
    ///
    /// - Parameter metrics: The metrics supplying the canonical gap.
    public init(metrics: CanvasMetrics) {
        self.metrics = metrics
    }

    /// Computes the frame for a new pane.
    ///
    /// - Parameters:
    ///   - size: The new pane's size.
    ///   - anchor: The focused pane's frame, when one exists. New panes appear
    ///     near it at the canonical gap.
    ///   - existing: Frames of every pane already on the canvas.
    /// - Returns: A frame at least ``CanvasMetrics/gap`` away from every
    ///   existing pane.
    public func frameForNewPane(
        size: CanvasSize,
        near anchor: CanvasRect?,
        avoiding existing: [CanvasRect]
    ) -> CanvasRect {
        guard !existing.isEmpty else {
            let origin = anchor?.origin ?? .zero
            return CanvasRect(origin: origin, size: size)
        }
        guard let anchor else {
            return frameRightOfContent(size: size, existing: existing)
        }

        let neighbors: [CanvasRect] = [
            CanvasRect(x: anchor.maxX + metrics.gap, y: anchor.minY, width: size.width, height: size.height),
            CanvasRect(x: anchor.minX, y: anchor.maxY + metrics.gap, width: size.width, height: size.height),
            CanvasRect(x: anchor.minX - metrics.gap - size.width, y: anchor.minY, width: size.width, height: size.height),
            CanvasRect(x: anchor.minX, y: anchor.minY - metrics.gap - size.height, width: size.width, height: size.height),
        ]
        for candidate in neighbors where isFree(candidate, avoiding: existing) {
            return candidate
        }

        // Scan a bounded grid rightward/downward from the anchor before falling back.
        for row in 0..<Self.scanRows {
            let y = anchor.minY + Double(row) * (size.height + metrics.gap)
            for column in 0..<Self.scanColumns {
                let x = anchor.maxX + metrics.gap + Double(column) * (size.width + metrics.gap)
                let candidate = CanvasRect(x: x, y: y, width: size.width, height: size.height)
                if isFree(candidate, avoiding: existing) {
                    return candidate
                }
            }
        }
        return frameRightOfContent(size: size, existing: existing)
    }

    private func isFree(_ candidate: CanvasRect, avoiding existing: [CanvasRect]) -> Bool {
        // Inset slightly so a candidate exactly one gap away from a neighbor counts as free.
        let probe = candidate.expandedBy(metrics.gap - 0.5)
        return !existing.contains(where: { probe.intersects($0) })
    }

    private func frameRightOfContent(size: CanvasSize, existing: [CanvasRect]) -> CanvasRect {
        let bounds = existing.dropFirst().reduce(existing[0]) { $0.union($1) }
        return CanvasRect(
            x: bounds.maxX + metrics.gap,
            y: bounds.minY,
            width: size.width,
            height: size.height
        )
    }
}
