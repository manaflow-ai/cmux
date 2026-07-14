import CmuxCore
import Foundation

/// Sidebar tooltip text for a workspace's remote connection state, including
/// the direct-vs-cloud-proxied mode label for connected SSH workspaces
/// (#8003 mode visibility). Extracted from `TabItemView` so the sidebar row
/// keeps only a thin computed property.
@MainActor
func sidebarRemoteStateHelpText(for tab: Workspace) -> String {
    let target = tab.remoteDisplayTarget ?? String(
        localized: "sidebar.remote.help.targetFallback",
        defaultValue: "remote host"
    )
    let detail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch tab.remoteConnectionState {
    case .connected:
        let connected = String(
            localized: "sidebar.remote.help.connected",
            defaultValue: "Remote connected to \(target)"
        )
        guard let transport = tab.remoteConfiguration?.transport else { return connected }
        let modeLabel = WorkspaceRemoteConnectionMode(transport: transport) == .direct
            ? String(
                localized: "sidebar.remote.help.modeDirect",
                defaultValue: "Direct (no cloud proxy): terminal, agent, and browser traffic flows straight to the host."
            )
            : String(
                localized: "sidebar.remote.help.modeCloudProxied",
                defaultValue: "Cloud-proxied: traffic is relayed through the cmux cloud."
            )
        return connected + "\n" + modeLabel
    case .connecting:
        return String(
            localized: "sidebar.remote.help.connecting",
            defaultValue: "Remote connecting to \(target)"
        )
    case .reconnecting:
        return String(
            localized: "sidebar.remote.help.reconnecting",
            defaultValue: "Remote reconnecting to \(target)"
        )
    case .error:
        if let detail, !detail.isEmpty {
            return String(
                localized: "sidebar.remote.help.errorWithDetail",
                defaultValue: "Remote error for \(target): \(detail)"
            )
        }
        return String(
            localized: "sidebar.remote.help.error",
            defaultValue: "Remote error for \(target)"
        )
    case .disconnected:
        return String(
            localized: "sidebar.remote.help.disconnected",
            defaultValue: "Remote disconnected from \(target)"
        )
    case .suspended:
        return String(
            localized: "sidebar.remote.help.suspended",
            defaultValue: "SSH host \(target) is unreachable. Automatic reconnect is paused — use Reconnect to retry."
        )
    }
}
