import CmuxSimulator
import Foundation

struct SimulatorAccessibilityOverlayFrame: Identifiable, Equatable {
    let id: String
    let rect: CGRect
    let node: SimulatorAccessibilityNode
}

func simulatorAccessibilityOverlayFrames(
    rows: [SimulatorAccessibilityPresentationRow],
    screenRect: CGRect
) -> [SimulatorAccessibilityOverlayFrame] {
    guard screenRect.width > 0, screenRect.height > 0,
          let coordinateSpace = rows.filter({ $0.depth == 0 }).compactMap(\.node.frame).max(by: {
              ($0.width * $0.height) < ($1.width * $1.height)
          }), coordinateSpace.width > 0, coordinateSpace.height > 0 else {
        return []
    }
    return rows.compactMap { row in
        guard let frame = row.node.frame,
              frame.x.isFinite, frame.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }
        let mapped = CGRect(
            x: screenRect.minX
                + ((frame.x - coordinateSpace.x) / coordinateSpace.width * screenRect.width),
            y: screenRect.minY
                + ((frame.y - coordinateSpace.y) / coordinateSpace.height * screenRect.height),
            width: frame.width / coordinateSpace.width * screenRect.width,
            height: frame.height / coordinateSpace.height * screenRect.height
        ).intersection(screenRect)
        guard mapped.width > 0, mapped.height > 0 else { return nil }
        return SimulatorAccessibilityOverlayFrame(id: row.id, rect: mapped, node: row.node)
    }
}
