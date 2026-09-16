import Foundation

extension Workspace {
#if DEBUG
    /// Test seam: portal lifecycle tests host surfaces that belong to no
    /// workspace, which the app authority reports as hidden. A test installs
    /// its own authority so the portal exercises visible entries.
    @MainActor
    static var portalRenderingAuthorityOverrideForTesting: ((UUID?) -> Bool)?
#endif

    /// Returns the authoritative portal-rendering state for a workspace id.
    ///
    /// Portal registries can outlive the SwiftUI representable that created an
    /// entry. They use this query at every bind/visibility boundary so queued
    /// callbacks cannot make an inactive workspace visible again. A missing
    /// app delegate is limited to isolated registry tests, where no workspace
    /// lifecycle exists to authorize or deny a portal.
    @MainActor
    static func portalRenderingEnabled(for workspaceID: UUID?) -> Bool {
#if DEBUG
        if let override = portalRenderingAuthorityOverrideForTesting { return override(workspaceID) }
#endif
        guard let workspaceID else { return true }
        guard let appDelegate = AppDelegate.shared else { return true }
        guard let manager = appDelegate.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
            return false
        }
        return manager.selectedTabId == workspaceID && workspace.isPortalRenderingEnabled
    }
}
