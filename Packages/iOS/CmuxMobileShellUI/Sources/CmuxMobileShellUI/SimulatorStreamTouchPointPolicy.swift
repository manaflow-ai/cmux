import CoreGraphics

enum SimulatorStreamTouchPointPolicy {
    private static let tapMovementThreshold: CGFloat = 6

    static func endPoint(start: CGPoint, location: CGPoint) -> CGPoint {
        let dx = location.x - start.x
        let dy = location.y - start.y
        let squaredDistance = (dx * dx) + (dy * dy)
        return squaredDistance <= tapMovementThreshold * tapMovementThreshold ? start : location
    }
}
