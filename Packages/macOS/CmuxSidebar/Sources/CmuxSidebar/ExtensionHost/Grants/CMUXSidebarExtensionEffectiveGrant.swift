public import CmuxExtensionKit

/// The scopes an installed sidebar extension is currently allowed to use,
/// computed by intersecting the manifest's requested scopes with the user's
/// stored grant (see ``CMUXSidebarExtensionGrantStore``).
public struct CMUXSidebarExtensionEffectiveGrant: Equatable {
    /// The manifest whose requested scopes were resolved against the grant.
    public var manifest: CmuxExtensionManifest
    /// Read scopes the extension is effectively allowed to use.
    public var readScopes: Set<CmuxExtensionScope>
    /// Action scopes the extension is effectively allowed to use.
    public var actionScopes: Set<CmuxExtensionActionScope>

    init(
        manifest: CmuxExtensionManifest,
        readScopes: Set<CmuxExtensionScope>,
        actionScopes: Set<CmuxExtensionActionScope>
    ) {
        self.manifest = manifest
        self.readScopes = readScopes
        self.actionScopes = actionScopes
    }

    /// True when the manifest requests scopes the effective grant does not yet
    /// cover, so the user has not approved everything the extension asks for.
    public var needsAdditionalApproval: Bool {
        !readScopes.isSuperset(of: manifest.readScopes) ||
            !actionScopes.isSuperset(of: manifest.actionScopes)
    }

    /// True when the effective grant includes any scope outside the default
    /// (non-sensitive) set.
    public var hasSensitiveAccess: Bool {
        readScopes.contains { !CMUXSidebarExtensionGrantStore.defaultReadScopes.contains($0) } ||
            actionScopes.contains { !CMUXSidebarExtensionGrantStore.defaultActionScopes.contains($0) }
    }
}
