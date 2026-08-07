import CmuxSidebar
import Foundation

/// Main-actor ownership needed to retire one visible Feed attention badge.
@MainActor
struct FeedPendingAttentionState {
    var fallbackWorkspace: Workspace?
    var statusEntry: SidebarStatusEntry
    var statusOwnerId: UUID
    var statusIsPanelScoped: Bool
    var processExitMonitorKey: String?
}
