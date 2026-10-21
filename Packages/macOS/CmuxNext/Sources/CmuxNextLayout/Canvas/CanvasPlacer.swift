public import CoreGraphics

/// Chooses a frame for a pane that joins a canvas (a split, a tab moved out):
/// beside the anchor pane at the canvas gap (right, below, left, above), else
/// the first free slot of a grid right of it, else right of everything. It
/// never moves a pane already there (classic `CanvasPlacer`).
public nonisolated struct CanvasPlacer: Hashable, Sendable {
    /// Space between a new pane and its neighbors, in canvas points.
    public var gap: CGFloat

    /// A placer that keeps `gap` canvas points between panes.
    public init(gap: CGFloat = CanvasScreen.gap) {
        self.gap = gap
    }

    /// A frame of `size` near `anchor` that overlaps none of `existing`, even
    /// within the gap.
    public func frame(size: CGSize, near anchor: CGRect?, avoiding existing: [CGRect]) -> CGRect {
        guard let first = existing.first else { return CGRect(origin: anchor?.origin ?? .zero, size: size) }
        let content = existing.dropFirst().reduce(first) { $0.union($1) }
        let base = anchor ?? content
        let beside = [
            CGRect(x: base.maxX + gap, y: base.minY, width: size.width, height: size.height),
            CGRect(x: base.minX, y: base.maxY + gap, width: size.width, height: size.height),
            CGRect(x: base.minX - gap - size.width, y: base.minY, width: size.width, height: size.height),
            CGRect(x: base.minX, y: base.minY - gap - size.height, width: size.width, height: size.height),
        ]
        if let free = beside.first(where: { isFree($0, existing) }) { return free }
        for row in 0..<8 {
            for column in 0..<16 {
                let candidate = CGRect(x: base.maxX + gap + CGFloat(column) * (size.width + gap),
                                       y: base.minY + CGFloat(row) * (size.height + gap), width: size.width, height: size.height)
                if isFree(candidate, existing) { return candidate }
            }
        }
        return CGRect(x: content.maxX + gap, y: content.minY, width: size.width, height: size.height)
    }

    private func isFree(_ candidate: CGRect, _ existing: [CGRect]) -> Bool {
        // A candidate exactly one gap from a neighbor is free.
        let probe = candidate.insetBy(dx: -(gap - 0.5), dy: -(gap - 0.5))
        return !existing.contains { probe.intersects($0) }
    }
}
