import SwiftUI

struct VNCPanelView: View {
    @ObservedObject var panel: VNCPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            VNCMetalCanvasRepresentable(panel: panel)
                .overlay {
                    if panel.latestFrame == nil {
                        Text(VNCPanelText.noFrame)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onRequestPanelFocus()
                    panel.focus()
                }
        }
        .background(Color(nsColor: appearance.backgroundColor))
        .task(id: panel.id) {
            panel.startIfNeeded()
        }
        .onChange(of: isVisibleInUI) { _, visible in
            panel.setVisible(visible)
        }
        .onAppear {
            panel.setVisible(isVisibleInUI)
        }
        .onDisappear {
            panel.setVisible(false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(panel.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                panel.reconnect()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(VNCPanelText.reconnect)
            .accessibilityLabel(VNCPanelText.reconnect)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(nsColor: appearance.backgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 1)
        }
    }

    private var statusText: String {
        switch panel.connectionState {
        case .idle:
            return VNCPanelText.stateIdle
        case .connecting:
            return VNCPanelText.stateConnecting
        case .connected:
            return VNCPanelText.stateConnected
        case .disconnected:
            return VNCPanelText.stateDisconnected
        case .failed:
            return VNCPanelText.stateFailed
        }
    }

    private var statusColor: Color {
        switch panel.connectionState {
        case .connected:
            return .green
        case .connecting, .idle:
            return .secondary
        case .disconnected, .failed:
            return .red
        }
    }
}
