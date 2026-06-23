public enum TerminalBackSwipeEdgeReservation {
    public static let defaultEdgeWidth: Double = 32

    public static func shouldReserveSystemBackSwipeEdge(
        touchXInWindow: Double,
        edgeWidth: Double = defaultEdgeWidth
    ) -> Bool {
        guard edgeWidth > 0, touchXInWindow >= 0 else {
            return false
        }

        return touchXInWindow <= edgeWidth
    }
}
