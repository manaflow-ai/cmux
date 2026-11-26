import CmuxSimulator
import CoreGraphics

struct SimulatorPointerEntry {
    let location: CGPoint
    let edge: SimulatorEdge
}

func simulatorPointerEntry(
    from start: CGPoint,
    to end: CGPoint,
    displayRect rect: CGRect
) -> SimulatorPointerEntry? {
    guard rect.width > 0, rect.height > 0 else { return nil }

    let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
    var entry = CGFloat.zero
    var exit = CGFloat(1)
    var entryEdge = SimulatorEdge.none
    var entryNormalMagnitude = CGFloat.zero

    func clip(
        _ direction: CGFloat,
        _ distance: CGFloat,
        edge: SimulatorEdge,
        normalMagnitude: CGFloat
    ) -> Bool {
        if abs(direction) < .ulpOfOne { return distance >= 0 }
        let ratio = distance / direction
        if direction < 0 {
            if ratio > entry
                || abs(ratio - entry) < .ulpOfOne && normalMagnitude >= entryNormalMagnitude
            {
                entry = ratio
                entryEdge = edge
                entryNormalMagnitude = normalMagnitude
            }
        } else {
            exit = min(exit, ratio)
        }
        return entry <= exit
    }

    guard clip(-delta.x, start.x - rect.minX, edge: .left, normalMagnitude: abs(delta.x)),
          clip(delta.x, rect.maxX - start.x, edge: .right, normalMagnitude: abs(delta.x)),
          clip(-delta.y, start.y - rect.minY, edge: .bottom, normalMagnitude: abs(delta.y)),
          clip(delta.y, rect.maxY - start.y, edge: .top, normalMagnitude: abs(delta.y)),
          (0...1).contains(entry) else { return nil }

    return SimulatorPointerEntry(
        location: CGPoint(
            x: min(max(start.x + (delta.x * entry), rect.minX), rect.maxX),
            y: min(max(start.y + (delta.y * entry), rect.minY), rect.maxY)
        ),
        edge: entryEdge
    )
}
