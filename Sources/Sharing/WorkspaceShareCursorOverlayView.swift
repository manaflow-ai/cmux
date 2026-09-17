import CmuxWorkspaceShare
import SwiftUI

struct WorkspaceShareCursorOverlayView: View {
    let pointers: [WorkspaceShareRemotePointer]
    let messagesByUserID: [String: String]
    let containerFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(pointers) { pointer in
                let color = WorkspaceShareParticipantColor.color(index: pointer.participant.color)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 0) {
                        WorkspaceShareCursorGlyph(color: color)
                        Text(pointer.participant.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.9))
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(color, in: RoundedRectangle(cornerRadius: 5))
                    }
                    if let message = messagesByUserID[pointer.participant.userId] {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                            }
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                }
                .offset(
                    x: containerFrame.minX + pointer.x * containerFrame.width
                        - WorkspaceShareCursorGeometry.hotspotInset,
                    y: containerFrame.minY + pointer.y * containerFrame.height
                        - WorkspaceShareCursorGeometry.hotspotInset
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

}

private struct WorkspaceShareCursorGlyph: View {
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let path = Self.path()
            context.stroke(
                path,
                with: .color(.white),
                style: StrokeStyle(
                    lineWidth: WorkspaceShareCursorGeometry.strokeWidth * WorkspaceShareCursorGeometry.scale,
                    lineJoin: .round
                )
            )
            context.fill(path, with: .color(color))
        }
        .frame(
            width: WorkspaceShareCursorGeometry.viewWidth,
            height: WorkspaceShareCursorGeometry.viewHeight
        )
        .accessibilityHidden(true)
    }

    private static func path() -> Path {
        let scale = WorkspaceShareCursorGeometry.scale
        var path = Path()
        for element in WorkspaceShareCursorGeometry.elements {
            switch element {
            case let .move(x, y):
                path.move(to: CGPoint(x: x * scale, y: y * scale))
            case let .line(x, y):
                path.addLine(to: CGPoint(x: x * scale, y: y * scale))
            case let .quadratic(controlX, controlY, x, y):
                path.addQuadCurve(
                    to: CGPoint(x: x * scale, y: y * scale),
                    control: CGPoint(x: controlX * scale, y: controlY * scale)
                )
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}
