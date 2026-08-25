import CmuxSidebar
import Foundation

/// Main-actor ownership needed to retire one visible Feed attention badge.
@MainActor
struct FeedPendingAttentionState {
    var fallbackWorkspace: Workspace?
    var statusEntry: SidebarStatusEntry
    /// The owner status that was visible before this attention contribution.
    /// Native approval attention temporarily uses the agent's lifecycle key;
    /// restoring this value keeps a running/idle status from being lost when
    /// the native prompt concludes.
    var previousStatusEntry: SidebarStatusEntry?
    var statusOwnerId: UUID
    var statusIsPanelScoped: Bool
    var processExitMonitorKey: String?
}
