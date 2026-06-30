public struct TerminalBackSwipeEdgeReservation: Sendable {
    private let edgeWidth: Double

    public init(edgeWidth: Double = 32) {
        self.edgeWidth = edgeWidth
    }

    public func shouldReserveSystemBackSwipeEdge(touchXInWindow: Double) -> Bool {
        guard edgeWidth > 0, touchXInWindow >= 0 else {
            return false
        }

        return touchXInWindow <= edgeWidth
    }
}
