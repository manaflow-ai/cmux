import CoreGraphics

struct SimulatorStreamTouchPointPolicy: Equatable {
    var tapMovementThreshold: CGFloat = 6

    func isDrag(start: CGPoint, location: CGPoint) -> Bool {
        squaredDistance(start: start, location: location) > tapMovementThreshold * tapMovementThreshold
    }

    func endPoint(start: CGPoint, location: CGPoint) -> CGPoint {
        isDrag(start: start, location: location) ? location : start
    }

    private func squaredDistance(start: CGPoint, location: CGPoint) -> CGFloat {
        let dx = location.x - start.x
        let dy = location.y - start.y
        return (dx * dx) + (dy * dy)
    }
}
