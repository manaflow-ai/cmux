import SwiftUI

struct ApplicationPanelView: View {
    let panel: ApplicationPanel
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ApplicationCaptureRepresentable(
            panel: panel,
            windowID: panel.windowID,
            isVisibleInUI: isVisibleInUI
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
                title: String(
                    localized: "panel.application.permissionRequired.title",
                    defaultValue: "Screen Recording permission required"
                ),
                detail: String(
                    localized: "panel.application.permissionRequired.detail",
                    defaultValue: "Allow Screen Recording for CMUX in System Settings, then restart CMUX."
                )
            )
        case .windowUnavailable:
            statusMessage(
                title: String(
                    localized: "panel.application.windowUnavailable.title",
                    defaultValue: "Application window unavailable"
                ),
                detail: String(
                    localized: "panel.application.windowUnavailable.detail",
                    defaultValue: "The application window is no longer available."
                )
            )
        case .failed:
            statusMessage(
                title: String(
                    localized: "panel.application.captureFailed.title",
                    defaultValue: "Application capture failed"
                ),
                detail: String(
                    localized: "panel.application.captureFailed.detail",
                    defaultValue: "CMUX could not capture this application window. Close the surface and try again."
                )
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
