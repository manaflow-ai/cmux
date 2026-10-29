
/// Where a painting's subject is: a normalized box in the artwork, measured from the top-left
/// corner (the faces, the ship, the vase). Catalog data: the window aspect-fills every work the
/// same way and does not frame it.
public nonisolated struct BackdropSubjectBox: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public nonisolated init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let clamp = { (value: Double, fallback: Double) in min(max(value.isFinite ? value : fallback, 0), 1) }
        let x0 = clamp(minX, 0), x1 = clamp(maxX, 1), y0 = clamp(minY, 0), y1 = clamp(maxY, 1)
        self.minX = min(x0, x1)
        self.maxX = max(x0, x1)
        self.minY = min(y0, y1)
        self.maxY = max(y0, y1)
    }

    /// A small box around a focal point, for art that names only a point.
    public nonisolated init(around anchor: BackdropFocalAnchor, width: Double = 0.2, height: Double = 0.3) {
        self.init(minX: anchor.x - width / 2, minY: anchor.y - height / 2, maxX: anchor.x + width / 2, maxY: anchor.y + height / 2)
    }

    public nonisolated var center: BackdropFocalAnchor { .init(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
}
