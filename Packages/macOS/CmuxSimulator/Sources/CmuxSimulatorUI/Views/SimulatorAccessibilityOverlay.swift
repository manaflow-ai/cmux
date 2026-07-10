import CmuxSimulator
import SwiftUI

struct SimulatorAccessibilityOverlay: View {
    let coordinator: SimulatorPaneCoordinator
    let snapshot: SimulatorAccessibilitySnapshot
    let chrome: SimulatorDeviceChromeProfile?

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let appKitScreen =
                chrome?.screenRect(
                    in: bounds,
                    orientation: snapshot.display.orientation
                ) ?? bounds
            let screen = CGRect(
                x: appKitScreen.minX,
                y: bounds.height - appKitScreen.maxY,
                width: appKitScreen.width,
                height: appKitScreen.height
            )
            let frames = simulatorAccessibilityOverlayFrames(
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
                            .overlay(
                                Rectangle().stroke(
                                    coordinator.accessibilityOverlaySelectedNodeID == item.node.id
                                        || coordinator.highlightedAccessibilityNodeID == item.node.id
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
