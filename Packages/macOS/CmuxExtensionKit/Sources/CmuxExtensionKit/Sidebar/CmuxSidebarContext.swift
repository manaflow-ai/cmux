import Foundation

/// Current sidebar state delivered by CMUX to a sidebar extension.
public struct CmuxSidebarContext: Sendable {
    /// Latest workspace snapshot filtered to the permissions granted by the user.
    public let snapshot: CmuxSidebarSnapshot

    /// Read scopes CMUX granted for this snapshot.
    public let grantedReadScopes: Set<CmuxExtensionScope>

    /// Host actions CMUX will currently accept from this extension.
    public let grantedActionScopes: Set<CmuxExtensionActionScope>

    /// Typed command channel back to CMUX.
    public let host: CmuxSidebarHost

    @MainActor
    public init(
        snapshot: CmuxSidebarSnapshot,
        grantedReadScopes: Set<CmuxExtensionScope>? = nil,
        grantedActionScopes: Set<CmuxExtensionActionScope>? = nil,
        host: CmuxSidebarHost
    ) {
        self.snapshot = snapshot
        self.grantedReadScopes = grantedReadScopes ?? snapshot.grantedReadScopes
        self.grantedActionScopes = grantedActionScopes ?? snapshot.grantedActionScopes
        self.host = host
    }
}
