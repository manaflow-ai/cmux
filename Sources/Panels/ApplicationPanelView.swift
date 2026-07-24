import SwiftUI

struct ApplicationPanelView: View {
    @ObservedObject var panel: ApplicationPanel
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ApplicationCaptureRepresentable(
            panel: panel,
            windowID: panel.windowID
        )
            .id(panel.windowID)
            .contentShape(Rectangle())
            .onTapGesture {
                onRequestPanelFocus()
            }
            .background(Color.black)
            .overlay {
                statusOverlay
            }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch panel.captureState {
        case .streaming:
            EmptyView()
        case .starting:
            ProgressView()
                .controlSize(.small)
        case .permissionRequired:
            statusMessage(
                title: String(localized: "panel.application.permissionRequired.title"),
                detail: String(localized: "panel.application.permissionRequired.detail")
            )
        case .windowUnavailable:
            statusMessage(
                title: String(localized: "panel.application.windowUnavailable.title"),
                detail: String(localized: "panel.application.windowUnavailable.detail")
            )
        case let .failed(detail):
            statusMessage(
                title: String(localized: "panel.application.captureFailed.title"),
                detail: detail
            )
        }
    }

    private func statusMessage(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "macwindow.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: 520)
    }
}
