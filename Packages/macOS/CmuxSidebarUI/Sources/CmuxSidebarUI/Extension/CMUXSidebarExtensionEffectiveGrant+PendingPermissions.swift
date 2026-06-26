public import CmuxSidebar
import CmuxExtensionKit

extension CMUXSidebarExtensionEffectiveGrant {
    /// Descriptions of every requested scope the effective grant does not yet
    /// cover, shown as bullets in the limited-access banner.
    ///
    /// Pending read-scope descriptions come first, then pending action-scope
    /// descriptions, each resolved through the package's
    /// `permissionDescription` helper.
    @_spi(CmuxHostTransport)
    public var pendingPermissionDescriptions: [String] {
        let pendingReadScopes = manifest.readScopes.filter {
            !readScopes.contains($0)
        }
        let pendingActionScopes = manifest.actionScopes.filter {
            !actionScopes.contains($0)
        }
        return pendingReadScopes.map(\.permissionDescription) +
            pendingActionScopes.map(\.permissionDescription)
    }
}
