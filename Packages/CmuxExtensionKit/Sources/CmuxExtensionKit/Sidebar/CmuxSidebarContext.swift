import Foundation

/// Current sidebar state delivered by CMUX to a sidebar extension.
public struct CmuxSidebarContext: Sendable {
    /// Latest workspace snapshot filtered to the permissions granted by the user.
    public let snapshot: CMUXSidebarSnapshot

    /// Read scopes CMUX granted for this snapshot.
    public let grantedReadScopes: Set<CMUXExtensionScope>

    /// Host actions CMUX will currently accept from this extension.
    public let grantedActionScopes: Set<CMUXExtensionActionScope>

    /// Typed command channel back to CMUX.
    public let host: CmuxSidebarHost

    /// Generic CMUX action channel for commands that are not sidebar-specific.
    public let cmux: CmuxHost

    @MainActor
    public init(
        snapshot: CMUXSidebarSnapshot,
        grantedReadScopes: Set<CMUXExtensionScope>? = nil,
        grantedActionScopes: Set<CMUXExtensionActionScope>? = nil,
        host: CmuxSidebarHost,
        cmux: CmuxHost? = nil
    ) {
        self.snapshot = snapshot
        self.grantedReadScopes = grantedReadScopes ?? snapshot.grantedReadScopes
        self.grantedActionScopes = grantedActionScopes ?? snapshot.grantedActionScopes
        self.host = host
        self.cmux = cmux ?? CmuxHost { action in
            await host.perform(action)
        }
    }
}
