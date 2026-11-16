import CoreGraphics

extension FocusNavigation {
    /// The focus rule of a screen that has floating panes: the part of ``neighbor(of:direction:frames:recency:columns:floating:)``
    /// that knows them. The tiled rule stays the rule between tiled panes; a floating pane is a stop on the way.
    ///
    /// From a tiled pane: the tiled rule gives the target. A floating pane STANDS BETWEEN when its centre is after
    /// the source's centre and before the target's centre on the key's axis and it overlaps the source on the other
    /// axis; the nearest such pane gets the focus. With no tiled target, the nearest floating pane after the source.
    ///
    /// From a floating pane: the origin is the tiled pane that had the focus before it (`recency`). The same key
    /// goes on: to the next floating pane between the origin and its target, then to that target, so a floating
    /// pane never traps the focus. The opposite key goes back the same way. Another key, or no origin, gives the
    /// nearest pane after the source by centres, one that overlaps the source on the other axis first.
    ///
    /// A tiled pane that one floating pane covers wholly is never a target: the user cannot see it.
    nonisolated struct FloatingRule {
        let frames: [PaneID: CGRect]
        let recency: [PaneID]
        let columns: [[PaneID]]
        /// The floating panes that have a frame, back to front, and each one's place in that order.
        let floating: [PaneID]
        let rank: [PaneID: Int]
        /// The tiled panes that can get the focus: each one that no floating pane covers wholly.
        let tiled: [PaneID: CGRect]

        init(frames: [PaneID: CGRect], recency: [PaneID], columns: [[PaneID]], floating: [PaneID]) {
            var rank: [PaneID: Int] = [:], shown: [PaneID] = [], covers: [CGRect] = []
            for pane in floating where rank[pane] == nil {
                guard let frame = frames[pane] else { continue }
                rank[pane] = shown.count
                shown.append(pane)
                covers.append(frame)
            }
            self.frames = frames
            self.recency = recency
            self.columns = columns
            self.floating = shown
            self.rank = rank
            tiled = frames.filter { pane, frame in rank[pane] == nil && !covers.contains { $0.contains(frame) } }
        }

        /// The pane that `direction` gives from `pane`, or nil.
        func neighbor(of pane: PaneID, _ direction: LayoutDirection) -> PaneID? {
            guard frames[pane] != nil else { return nil }
            guard rank[pane] != nil else {
                let way = lane(from: pane, direction)
                if let first = way.members.first { return first }
                if let target = way.target { return target }
                return floating.filter { isAfter($0, pane, direction) }.min { isAfter($1, $0, direction) }
            }
            if let origin = recency.first(where: { $0 != pane && tiled[$0] != nil }) {
                let way = lane(from: origin, direction)
                if let index = way.members.firstIndex(of: pane) {
                    if index + 1 < way.members.count { return way.members[index + 1] }
                    return way.target ?? nearest(after: pane, direction)
                }
                let back = lane(from: origin, Self.opposite(direction)).members
                if let index = back.firstIndex(of: pane) { return index > 0 ? back[index - 1] : origin }
            }
            return nearest(after: pane, direction)
        }

        /// The tiled target of `origin` in `direction`, and the floating panes that stand between the two, the
        /// nearest to `origin` first.
        private func lane(from origin: PaneID, _ direction: LayoutDirection) -> (members: [PaneID], target: PaneID?) {
            guard let source = frames[origin] else { return ([], nil) }
            // The origin is a candidate's source also when a floating pane covers it wholly.
            var around = tiled
            around[origin] = source
            let known = columns.map { $0.filter { around[$0] != nil } }
            let target = FocusNavigation.neighbor(of: origin, direction: direction, frames: around, recency: recency, columns: known)
            let members = floating.filter { pane in
                guard let frame = frames[pane], isAfter(pane, origin, direction) else { return false }
                return Self.crossOverlap(frame, source, direction) > 0 && (target.map { isAfter($0, pane, direction) } ?? true)
            }
            return (members.sorted { isAfter($1, $0, direction) }, target)
        }

        /// The nearest pane after `pane` in `direction` by centres: one that overlaps it on the other axis first.
        private func nearest(after pane: PaneID, _ direction: LayoutDirection) -> PaneID? {
            guard let source = frames[pane] else { return nil }
            let candidates = (Array(tiled.keys) + floating).filter { $0 != pane && isAfter($0, pane, direction) }
            let overlapping = candidates.filter { Self.crossOverlap(frames[$0] ?? .zero, source, direction) > 0 }
            func order(_ other: PaneID) -> (CGFloat, CGFloat, Int, Int, String) {
                let frame = frames[other] ?? .zero, horizontal = Self.isHorizontal(direction)
                return (abs(Self.centre(frame, direction) - Self.centre(source, direction)),
                        horizontal ? abs(frame.midY - source.midY) : abs(frame.midX - source.midX),
                        rank[other] == nil ? 0 : 1, rank[other] ?? 0, other.rawValue)
            }
            return (overlapping.isEmpty ? candidates : overlapping).min { order($0) < order($1) }
        }

        /// Whether `first` is after `second` in `direction`: by the centre on the key's axis, then a floating pane
        /// after a tiled one, then the pane more to the front. No two panes are equal in this order.
        private func isAfter(_ first: PaneID, _ second: PaneID, _ direction: LayoutDirection) -> Bool {
            let (a, b) = (place(first, direction), place(second, direction))
            return direction == .right || direction == .down ? a > b : a < b
        }

        private func place(_ pane: PaneID, _ direction: LayoutDirection) -> (CGFloat, Int, Int) {
            (Self.centre(frames[pane] ?? .zero, direction), rank[pane] == nil ? 0 : 1, rank[pane] ?? 0)
        }

        private static func isHorizontal(_ direction: LayoutDirection) -> Bool { direction == .left || direction == .right }

        private static func centre(_ frame: CGRect, _ direction: LayoutDirection) -> CGFloat {
            isHorizontal(direction) ? frame.midX : frame.midY
        }

        /// How much 2 frames share on the axis that `direction` does not move on.
        private static func crossOverlap(_ first: CGRect, _ second: CGRect, _ direction: LayoutDirection) -> CGFloat {
            isHorizontal(direction)
                ? min(first.maxY, second.maxY) - max(first.minY, second.minY)
                : min(first.maxX, second.maxX) - max(first.minX, second.minX)
        }

        private static func opposite(_ direction: LayoutDirection) -> LayoutDirection {
            switch direction {
            case .left: .right
            case .right: .left
            case .up: .down
            case .down: .up
            }
        }
    }
}
