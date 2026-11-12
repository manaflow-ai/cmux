import Foundation

extension Workspace {
    /// Returns the authoritative portal-rendering state for a workspace id.
    ///
    /// Portal registries can outlive the SwiftUI representable that created an
    /// entry. They use this query at every bind/visibility boundary so queued
    /// callbacks cannot make an inactive workspace visible again. A missing
    /// app delegate is limited to isolated registry tests, where no workspace
    /// lifecycle exists to authorize or deny a portal.
    @MainActor
    static func portalRenderingEnabled(for workspaceID: UUID?) -> Bool {
        guard let workspaceID else { return true }
        guard let appDelegate = AppDelegate.shared else { return true }
        guard let manager = appDelegate.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
            return false
        }
        return manager.selectedTabId == workspaceID && workspace.isPortalRenderingEnabled
    }
}
