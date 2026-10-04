import CoreGraphics

/// The spaces as pages in dot order (R99).
nonisolated struct SpacePager: Equatable, Sendable {
    var index: Int
    var count: Int
    private(set) var offset: CGFloat = 0

    init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }

    var neighbor: Int? { nil }
    mutating func drag(by points: CGFloat, width: CGFloat) {}
    func target(velocity: CGFloat, width: CGFloat) -> Int { index }
    static func direction(from: Int, to: Int) -> Int { 0 }
}
