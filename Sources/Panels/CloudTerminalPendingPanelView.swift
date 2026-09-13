import SwiftUI
import CmuxAppKitSupportUI

/// Shows progress or a recoverable failure while a Cloud terminal pane is created.
struct CloudTerminalPendingPanelView: View {
    let panel: CloudTerminalPendingPanel

    var body: some View {
        VStack(spacing: 14) {
            switch panel.state.phase {
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "cloudTerminal.creation.starting", defaultValue: "Starting Cloud terminal"))
                    .cmuxFont(size: 14, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(String(localized: "cloudTerminal.creation.waiting", defaultValue: "Waiting for the Cloud service to accept the terminal."))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            case .failed(let detail):
                CmuxSystemSymbolImage(systemName: "exclamationmark.triangle.fill", pointSize: 18, tint: .orange)
                Text(String(localized: "cloudTerminal.creation.failed.title", defaultValue: "Cloud terminal could not start"))
                    .cmuxFont(size: 14, weight: .semibold)
                    .foregroundStyle(.primary)
                Text(detail)
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button {
                    panel.retry()
                } label: {
                    Label(
                        String(localized: "cloudTerminal.creation.retry", defaultValue: "Retry"),
                        systemImage: "arrow.clockwise"
                    )
                    .cmuxFont(size: 12, weight: .semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
    }
}
