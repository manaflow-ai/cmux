import CoreGraphics

/// Resolves pane focus only after a stationary tap wins against scrolling and dragging.
struct PaneMapSelectionArbitration: Equatable {
    private static let maximumTapTravel: CGFloat = 10

    private var touchOrigin: CGPoint?
    private var absorbedByMovement = false

    mutating func touchBegan(at point: CGPoint) {
        touchOrigin = point
        absorbedByMovement = false
    }

    mutating func touchMoved(to point: CGPoint) {
        guard let touchOrigin else { return }
        let travel = hypot(point.x - touchOrigin.x, point.y - touchOrigin.y)
        if travel > Self.maximumTapTravel {
            absorbedByMovement = true
        }
    }

    mutating func dragSessionDidBegin() {
        absorbedByMovement = true
    }

    mutating func touchEnded(at point: CGPoint) -> Bool {
        touchMoved(to: point)
        defer {
            touchOrigin = nil
            absorbedByMovement = false
        }
        return touchOrigin != nil && !absorbedByMovement
    }

    mutating func cancel() {
        touchOrigin = nil
        absorbedByMovement = false
    }
}
