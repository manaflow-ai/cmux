public import CoreGraphics

/// Directional pane navigation over computed frames, with focus history
/// (plans/cmux-next/focus.md section 4a).
public nonisolated enum FocusNavigation {
    /// The pane `direction` of `pane`.
    ///
    /// Candidates lie entirely past the source edge. The adjacent ones are
    /// those that overlap the source on the perpendicular axis at the
    /// smallest distance (tmux `window_pane_find_*`, zellij
    /// `next_selectable_pane_id_*`). Among them the most recently focused
    /// wins (`recency`, newest first; tmux `window_pane_choose_best`, zellij
    /// `max_by_key(active_at)`); without history the largest overlap, then
    /// the nearest center, then the top-left one. When no candidate overlaps,
    /// the nearest edge, then the nearest center.
    ///
    /// `columns` (niri columns mode, panes per column) makes a move into
    /// another column land on that column's most recently focused pane,
    /// wherever it sits in the column (niri keeps an active tile per column).
    public static func neighbor(
        of pane: PaneID,
        direction: LayoutDirection,
        frames: [PaneID: CGRect],
        recency: [PaneID] = [],
        columns: [[PaneID]] = []
    ) -> PaneID? {
        guard let source = frames[pane] else { return nil }
        let candidates = frames.compactMap { id, rect in
            id == pane ? nil : Candidate(id: id, rect: rect, source: source, direction: direction)
        }
        let overlapping = candidates.filter { $0.overlap > 0 }
        let chosen: PaneID?
        if let nearest = overlapping.map(\.distance).min() {
            let adjacent = overlapping.filter { $0.distance <= nearest + epsilon }
            chosen = mostRecent(adjacent.map(\.id), recency: recency)
                ?? adjacent.min { $0.adjacentOrder < $1.adjacentOrder }?.id
        } else {
            chosen = candidates.min { $0.fallbackOrder < $1.fallbackOrder }?.id
        }
        guard let chosen else { return nil }
        if direction == .left || direction == .right,
           let column = columns.first(where: { $0.contains(chosen) }), !column.contains(pane),
           let remembered = mostRecent(column, recency: recency) {
            return remembered
        }
        return chosen
    }

    /// The member of `panes` that comes first in `recency` (newest first).
    public static func mostRecent(_ panes: [PaneID], recency: [PaneID]) -> PaneID? {
        let members = Set(panes)
        return recency.first { members.contains($0) }
    }

    static let epsilon: CGFloat = 1.5

    private struct Candidate {
        let id: PaneID
        let rect: CGRect
        let distance: CGFloat
        let overlap: CGFloat
        let centerOffset: CGFloat

        init?(id: PaneID, rect: CGRect, source: CGRect, direction: LayoutDirection) {
            let epsilon = FocusNavigation.epsilon
            switch direction {
            case .left:
                guard rect.maxX <= source.minX + epsilon else { return nil }
                distance = source.minX - rect.maxX
            case .right:
                guard rect.minX >= source.maxX - epsilon else { return nil }
                distance = rect.minX - source.maxX
            case .up:
                guard rect.maxY <= source.minY + epsilon else { return nil }
                distance = source.minY - rect.maxY
            case .down:
                guard rect.minY >= source.maxY - epsilon else { return nil }
                distance = rect.minY - source.maxY
            }
            switch direction {
            case .left, .right:
                overlap = min(rect.maxY, source.maxY) - max(rect.minY, source.minY)
                centerOffset = abs(rect.midY - source.midY)
            case .up, .down:
                overlap = min(rect.maxX, source.maxX) - max(rect.minX, source.minX)
                centerOffset = abs(rect.midX - source.midX)
            }
            self.id = id
            self.rect = rect
        }

        /// Adjacent panes without history: largest overlap, nearest center,
        /// then top-left (deterministic, never dictionary order).
        var adjacentOrder: (CGFloat, CGFloat, CGFloat, CGFloat, String) {
            (-overlap.rounded(), centerOffset.rounded(), rect.minY, rect.minX, id.rawValue)
        }

        /// No overlapping pane: nearest edge, nearest center, top-left.
        var fallbackOrder: (CGFloat, CGFloat, CGFloat, CGFloat, String) {
            (distance.rounded(), centerOffset, rect.minY, rect.minX, id.rawValue)
        }
    }
}
