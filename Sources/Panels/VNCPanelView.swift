import AppKit
import CmuxVNC
import SwiftUI

/// Hosts a ``VNCPanel``'s native framebuffer surface and overlays connection
/// status. The pixel path is entirely native (CALayer); SwiftUI only draws the
/// surrounding chrome.
struct VNCPanelView: View {
    @ObservedObject var panel: VNCPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ZStack {
            Color.black

            VNCSurfaceHost(panel: panel, isFocused: isFocused, onRequestPanelFocus: onRequestPanelFocus)
                .id(panel.sessionToken)

            statusOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch panel.connectionState {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "vnc.status.connecting", defaultValue: "Connecting…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                Text(panel.endpoint.displayLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(20)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        case .disconnected(let message):
            VStack(spacing: 12) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
                Text(String(localized: "vnc.status.disconnected", defaultValue: "Disconnected"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                Button {
                    panel.reconnect()
                } label: {
                    Text(String(localized: "vnc.action.reconnect", defaultValue: "Reconnect"))
                }
                .controlSize(.regular)
            }
            .padding(24)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        case .connected:
            EmptyView()
        }
    }
}

/// Bridges the package's `VNCSurfaceView` into SwiftUI. The panel owns the view
/// instance; recreation is driven by `panel.sessionToken` via `.id(...)`.
private struct VNCSurfaceHost: NSViewRepresentable {
    let panel: VNCPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    func makeNSView(context: Context) -> VNCSurfaceView {
        let view = panel.surfaceView
        view.onFocusRequested = onRequestPanelFocus
        return view
    }

    func updateNSView(_ nsView: VNCSurfaceView, context: Context) {
        nsView.onFocusRequested = onRequestPanelFocus
        if isFocused, nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}
