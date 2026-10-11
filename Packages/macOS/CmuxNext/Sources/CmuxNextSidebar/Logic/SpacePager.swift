import CoreGraphics

/// The spaces as pages side by side in dot order (R99). `offset` is in
/// pages: +1 shows the next space fully, -1 the previous one. A drag moves
/// the pages 1:1 with the fingers; past the first or last space it
/// rubber-bands. A release snaps by distance or velocity.
nonisolated struct SpacePager: Equatable, Sendable {
    /// How far past the end the band can ever show, in pages.
    static let bandLimit: CGFloat = 0.15
    /// A flick faster than this (in pages per second) decides the release.
    static let flickVelocity: CGFloat = 1.5

    var index: Int
    var count: Int
    /// Where the fingers have taken the pages (unbanded), in pages.
    private(set) var raw: CGFloat = 0

    init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }

    /// The offset the sidebar shows: `raw`, banded where no page is.
    var offset: CGFloat {
        guard raw != 0, neighbor(toward: raw) == nil else { return raw }
        let limit = Self.bandLimit, distance = abs(raw)
        return (raw > 0 ? 1 : -1) * limit * (1 - 1 / (distance / limit + 1))
    }

    /// The page beside the current one on the side the pages moved to.
    var neighbor: Int? { raw == 0 ? nil : neighbor(toward: raw) }

    private func neighbor(toward side: CGFloat) -> Int? {
        let next = index + (side > 0 ? 1 : -1)
        return (0..<count).contains(next) ? next : nil
    }

    /// Fingers moved `points` (positive: to the right, toward the previous space).
    mutating func drag(by points: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        raw = min(max(raw - points / width, -1), 1)
    }

    /// The page a release settles on, with the fingers' velocity in points
    /// per second (positive: to the right).
    func target(velocity: CGFloat, width: CGFloat) -> Int {
        guard width > 0, let neighbor else { return index }
        let pages = -velocity / width
        let towardNeighbor = (raw > 0) == (pages > 0)
        if abs(pages) >= Self.flickVelocity { return towardNeighbor ? neighbor : index }
        return abs(raw) >= 0.5 ? neighbor : index
    }

    /// The side a switch from `from` to `to` slides in from: +1 the trailing
    /// edge (a later dot), -1 the leading edge, 0 none.
    static func direction(from: Int, to: Int) -> Int { to == from ? 0 : (to > from ? 1 : -1) }
}
