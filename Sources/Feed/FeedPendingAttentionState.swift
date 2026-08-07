import CmuxSidebar
import Foundation

/// Main-actor ownership needed to retire one visible Feed attention badge.
@MainActor
struct FeedPendingAttentionState {
    let fallbackWorkspace: Workspace
    let statusEntry: SidebarStatusEntry
    let statusOwnerId: UUID
    let statusIsPanelScoped: Bool
    var processExitMonitorKey: String?
}
