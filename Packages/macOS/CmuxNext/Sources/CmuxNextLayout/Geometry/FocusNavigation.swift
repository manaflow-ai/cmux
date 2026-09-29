public import CoreGraphics

/// Directional pane navigation over computed frames.
public nonisolated enum FocusNavigation {
    /// The pane nearest `pane` in `direction`. Candidates must lie entirely
    /// past the source edge; panes that overlap the source on the
    /// perpendicular axis win, then the nearest edge, then the nearest center.
    public static func neighbor(of pane: PaneID, direction: LayoutDirection, frames: [PaneID: CGRect]) -> PaneID? {
        guard let source = frames[pane] else { return nil }
        let epsilon: CGFloat = 1.5
        var best: (id: PaneID, score: (Int, CGFloat, CGFloat))?
        for (id, rect) in frames where id != pane {
            let distance: CGFloat
            let overlap: CGFloat
            let centerOffset: CGFloat
            switch direction {
            case .left:
                guard rect.maxX <= source.minX + epsilon else { continue }
                distance = source.minX - rect.maxX
                overlap = min(rect.maxY, source.maxY) - max(rect.minY, source.minY)
                centerOffset = abs(rect.midY - source.midY)
            case .right:
                guard rect.minX >= source.maxX - epsilon else { continue }
                distance = rect.minX - source.maxX
                overlap = min(rect.maxY, source.maxY) - max(rect.minY, source.minY)
                centerOffset = abs(rect.midY - source.midY)
            case .up:
                guard rect.maxY <= source.minY + epsilon else { continue }
                distance = source.minY - rect.maxY
                overlap = min(rect.maxX, source.maxX) - max(rect.minX, source.minX)
                centerOffset = abs(rect.midX - source.midX)
            case .down:
                guard rect.minY >= source.maxY - epsilon else { continue }
                distance = rect.minY - source.maxY
                overlap = min(rect.maxX, source.maxX) - max(rect.minX, source.minX)
                centerOffset = abs(rect.midX - source.midX)
            }
            let score = (overlap > 0 ? 0 : 1, distance.rounded(), centerOffset)
            if let current = best, !(score < current.score) { continue }
            best = (id, score)
        }
        return best?.id
    }
}
