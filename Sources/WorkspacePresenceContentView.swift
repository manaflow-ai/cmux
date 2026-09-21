import SwiftUI

extension ContentView {
    /// Keeps the process-wide presence heartbeat aligned with this window's
    /// selected workspace and the right-sidebar projection.
    func syncWorkspacePresenceScope() {
        AppDelegate.shared?.workspacePresenceController.setActiveWorkspaceScope(
            WorkspacePresenceScope.identifier(for: tabManager.selectedWorkspace)
        )
    }
}
