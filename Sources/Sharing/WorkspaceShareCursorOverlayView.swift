import CmuxWorkspaceShare
import SwiftUI

struct WorkspaceShareCursorOverlayView: View {
    let pointers: [WorkspaceShareRemotePointer]
    let messagesByUserID: [String: String]
    let containerFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(pointers) { pointer in
                let color = Self.color(index: pointer.participant.color)
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

    private static func color(index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 1, green: 0.36, blue: 0.48),
            Color(red: 0.31, green: 0.89, blue: 0.76),
            Color(red: 0.49, green: 0.55, blue: 1),
            Color(red: 1, green: 0.74, blue: 0.29),
            Color(red: 0.83, green: 0.47, blue: 1),
            Color(red: 0.33, green: 0.72, blue: 1),
            Color(red: 1, green: 0.5, blue: 0.31),
            Color(red: 0.41, green: 0.83, blue: 0.43),
            Color(red: 0.97, green: 0.42, blue: 0.83),
            Color(red: 0.19, green: 0.84, blue: 0.93),
            Color(red: 0.84, green: 0.85, blue: 0.3),
            Color(red: 0.67, green: 0.57, blue: 1),
        ]
        return palette[abs(index) % palette.count]
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

struct WorkspaceShareChatOverlayView: View {
    let messages: [WorkspaceShareChatMessage]
    let onSend: @MainActor (String) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.secondary)
                Text(String(localized: "workspaceShare.chat.title", defaultValue: "Workspace chat"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(messages, id: \.id) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.displayName)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Self.color(index: message.color))
                            Text(message.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }

            Divider()

            HStack(spacing: 6) {
                TextField(
                    String(localized: "workspaceShare.chat.placeholder", defaultValue: "Message everyone"),
                    text: $draft
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(String(localized: "workspaceShare.chat.send", defaultValue: "Send"))
            }
            .padding(8)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(String(text.prefix(500)))
        draft = ""
    }

    private static func color(index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 1, green: 0.36, blue: 0.48),
            Color(red: 0.31, green: 0.89, blue: 0.76),
            Color(red: 0.49, green: 0.55, blue: 1),
            Color(red: 1, green: 0.74, blue: 0.29),
            Color(red: 0.83, green: 0.47, blue: 1),
            Color(red: 0.33, green: 0.72, blue: 1),
            Color(red: 1, green: 0.5, blue: 0.31),
            Color(red: 0.41, green: 0.83, blue: 0.43),
            Color(red: 0.97, green: 0.42, blue: 0.83),
            Color(red: 0.19, green: 0.84, blue: 0.93),
            Color(red: 0.84, green: 0.85, blue: 0.3),
            Color(red: 0.67, green: 0.57, blue: 1),
        ]
        return palette[Int(index.magnitude % UInt(palette.count))]
    }
}
