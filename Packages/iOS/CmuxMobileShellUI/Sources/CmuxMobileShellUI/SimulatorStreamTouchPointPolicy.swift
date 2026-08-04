import CoreGraphics

struct SimulatorStreamTouchPointPolicy: Equatable {
    var tapMovementThreshold: CGFloat = 6

    func endPoint(start: CGPoint, location: CGPoint) -> CGPoint {
        let dx = location.x - start.x
        let dy = location.y - start.y
        let squaredDistance = (dx * dx) + (dy * dy)
        return squaredDistance <= tapMovementThreshold * tapMovementThreshold ? start : location
    }
}
