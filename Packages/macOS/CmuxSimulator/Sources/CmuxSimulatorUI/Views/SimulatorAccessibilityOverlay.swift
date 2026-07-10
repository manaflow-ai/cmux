import CmuxSimulator
import SwiftUI

struct SimulatorAccessibilityOverlayFrame: Identifiable, Equatable {
    let id: String
    let rect: CGRect
    let node: SimulatorAccessibilityNode
}

enum SimulatorAccessibilityOverlayLayout {
    static func frames(
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
}

struct SimulatorAccessibilityOverlay: View {
    let coordinator: SimulatorPaneCoordinator
    let snapshot: SimulatorAccessibilitySnapshot
    let chrome: SimulatorDeviceChromeProfile?

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let appKitScreen = chrome?.screenRect(
                in: bounds,
                orientation: snapshot.display.orientation
            ) ?? bounds
            let screen = CGRect(
                x: appKitScreen.minX,
                y: bounds.height - appKitScreen.maxY,
                width: appKitScreen.width,
                height: appKitScreen.height
            )
            let frames = SimulatorAccessibilityOverlayLayout.frames(
                rows: coordinator.accessibilityRows,
                screenRect: screen
            )
            ZStack(alignment: .topLeading) {
                ForEach(frames) { item in
                    Button {
                        coordinator.selectAccessibilityOverlayNode(item.node)
                    } label: {
                        Rectangle()
                            .fill(.blue.opacity(0.08))
                            .overlay(Rectangle().stroke(
                                coordinator.accessibilityOverlaySelectedNodeID == item.node.id
                                    ? Color.red : Color.blue,
                                lineWidth: 1
                            ))
                    }
                    .buttonStyle(.plain)
                    .frame(width: item.rect.width, height: item.rect.height)
                    .position(x: item.rect.midX, y: item.rect.midY)
                    .help(item.node.label ?? item.node.roleDescription ?? item.node.role ?? item.node.id)
                }
            }
        }
    }
}
