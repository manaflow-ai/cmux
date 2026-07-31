import CmuxMobileSupport
import SwiftUI

/// The Mail-style "Checking for Mail…" analogue: a caption status line shown
/// while the connection is degraded. On iOS it renders under the computers
/// picker title in the navigation bar; on macOS the workspace list renders it
/// as a slim inline row.
struct WorkspaceConnectionStatusLineView: View {
    let line: WorkspaceConnectionStatusLine

    var body: some View {
        HStack(spacing: 4) {
            if line == .reconnecting {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.72)
                    .tint(.secondary)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(Self.text(for: line))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityIdentifier("MobileWorkspaceConnectionStatusLine")
    }

    static func text(for line: WorkspaceConnectionStatusLine) -> String {
        switch line {
        case .reconnecting:
            return L10n.string(
                "mobile.workspaces.statusLine.reconnecting",
                defaultValue: "Reconnecting…"
            )
        case .notConnected:
            return L10n.string(
                "mobile.workspaces.statusLine.notConnected",
                defaultValue: "Not Connected"
            )
        }
    }
}
