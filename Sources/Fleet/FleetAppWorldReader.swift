import CmuxFleet
import CmuxSidebarGit
import Foundation

/// Reads app workspace and sidebar state for Fleet reconciliation.
@MainActor
final class FleetAppWorldReader: FleetWorldReading {
    /// Returns whether the workspace still exists in any tab manager.
    func workspaceExists(workspaceID: String) -> Bool {
        guard let workspaceID = UUID(uuidString: workspaceID) else { return false }
        return AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?
            .tabs
            .contains(where: { $0.id == workspaceID }) ?? false
    }

    /// Returns the workspace's current sidebar pull-request badge, if present.
    func pullRequestStatus(workspaceID: String, directoryPath: String?, branch: String?) -> FleetPullRequestStatus? {
        guard let workspaceUUID = UUID(uuidString: workspaceID),
              let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceUUID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceUUID }),
              let panelID = workspace.focusedTerminalPanel?.id ?? workspace.focusedPanelId,
              let badge = tabManager.panelPullRequestBadge(workspaceId: workspaceUUID, panelId: panelID)
        else { return nil }
        return FleetPullRequestStatus(
            number: badge.number,
            url: badge.url,
            state: FleetPullRequestState(rawValue: badge.status.rawValue),
            ciSummary: nil
        )
    }

    /// Returns whether the tracked terminal panel is currently prompt-idle.
    func isShellPromptIdle(workspaceID: String, surfaceID: String) -> Bool? {
        guard let workspaceUUID = UUID(uuidString: workspaceID),
              let surfaceUUID = UUID(uuidString: surfaceID),
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceUUID)?
                .tabs
                .first(where: { $0.id == workspaceUUID })
        else { return nil }
        return workspace.panelShellActivityStates[surfaceUUID] == .promptIdle
    }
}
