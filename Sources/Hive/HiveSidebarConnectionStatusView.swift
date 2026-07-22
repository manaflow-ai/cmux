import CmuxHive
import SwiftUI

/// Placeholder shown in place of the workspace list when the sidebar is
/// scoped to a single paired computer (``HiveSidebarScope/device(_:)``) and
/// has zero mirrored workspaces to show. Without this, an offline or still-
/// connecting computer renders a fully blank sidebar with no indication of
/// why — the mirror attach loop
/// (`HiveComputerMirrorController.attach(deviceID:into:)`) gives up silently
/// after ~10s, and the sidebar's scope filter then has nothing to display.
///
/// Reuses the same localized strings and phase mapping as
/// `HiveViewerRootView` in CmuxHiveUI (the standalone viewer window's
/// connecting/failed states) so both surfaces read identically.
struct HiveSidebarConnectionStatusView: View {
    enum Status: Equatable {
        /// No attach attempt has been observed yet.
        case neverAttempted
        case connecting
        case failed(message: String)
        /// The session is connected but the remote genuinely has zero
        /// workspaces (or the user closed every mirrored one locally).
        case connectedEmpty

        init(phase: HiveRemoteMacSession.Phase?) {
            switch phase {
            case nil, .idle:
                self = .neverAttempted
            case .connecting, .reconnecting:
                self = .connecting
            case .connected:
                self = .connectedEmpty
            case .failed(let message):
                self = .failed(message: message)
            }
        }
    }

    let deviceName: String
    let status: Status
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(deviceName)
                .font(.headline)
                .foregroundStyle(.secondary)
            switch status {
            case .neverAttempted, .connecting:
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "hive.viewer.connecting", defaultValue: "Connecting…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(String(localized: "hive.viewer.failed.title", defaultValue: "Couldn't Connect"))
                    .font(.callout)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "hive.viewer.retry", defaultValue: "Retry"), action: onRetry)
                    .controlSize(.small)
            case .connectedEmpty:
                Text(String(localized: "hive.sidebar.status.noWorkspaces", defaultValue: "No open workspaces"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("HiveSidebarConnectionStatus")
    }
}
