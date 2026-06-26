public import CmuxExtensionKit
public import Foundation

/// `UserDefaults`-backed repository of per-extension scope grants.
///
/// Resolves a manifest's requested scopes against the user's stored grant into a
/// ``CMUXSidebarExtensionEffectiveGrant``, and persists grant/revoke decisions.
public struct CMUXSidebarExtensionGrantStore {
    /// Read scopes available without explicit user approval.
    static let defaultReadScopes: Set<CmuxExtensionScope> = []
    /// Action scopes available without explicit user approval.
    static let defaultActionScopes: Set<CmuxExtensionActionScope> = []

    private static let defaultsKey = "cmuxExtensionSidebar.grants.v1"

    /// Defaults store the grants are read from and written to.
    public var defaults: UserDefaults

    /// Creates a grant store backed by the given defaults (the standard suite by
    /// default).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Resolves the manifest's requested scopes against the stored grant.
    ///
    /// When there is no matching grant (or it predates a manifest id / API
    /// version change) the requested scopes are intersected with the defaults;
    /// otherwise they are intersected with the granted scopes.
    public func effectiveGrant(
        bundleIdentifier: String,
        manifest: CmuxExtensionManifest
    ) -> CMUXSidebarExtensionEffectiveGrant {
        let requestedReadScopes = Set(manifest.readScopes)
        let requestedActionScopes = Set(manifest.actionScopes)
        guard let grant = storedGrants()[bundleIdentifier],
              grant.manifestID == manifest.id,
              grant.apiVersion == manifest.minimumAPIVersion else {
            return CMUXSidebarExtensionEffectiveGrant(
                manifest: manifest,
                readScopes: requestedReadScopes.intersection(Self.defaultReadScopes),
                actionScopes: requestedActionScopes.intersection(Self.defaultActionScopes)
            )
        }
        return CMUXSidebarExtensionEffectiveGrant(
            manifest: manifest,
            readScopes: requestedReadScopes.intersection(grant.readScopes),
            actionScopes: requestedActionScopes.intersection(grant.actionScopes)
        )
    }

    /// Grants the extension every scope its manifest requests.
    public func grantRequestedAccess(bundleIdentifier: String, manifest: CmuxExtensionManifest) {
        updateGrant(
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            readScopes: Set(manifest.readScopes),
            actionScopes: Set(manifest.actionScopes)
        )
    }

    /// Revokes everything beyond the default (non-sensitive) scopes.
    public func revokeSensitiveAccess(bundleIdentifier: String, manifest: CmuxExtensionManifest) {
        updateGrant(
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            readScopes: Set(manifest.readScopes).intersection(Self.defaultReadScopes),
            actionScopes: Set(manifest.actionScopes).intersection(Self.defaultActionScopes)
        )
    }

    private func updateGrant(
        bundleIdentifier: String,
        manifest: CmuxExtensionManifest,
        readScopes: Set<CmuxExtensionScope>,
        actionScopes: Set<CmuxExtensionActionScope>
    ) {
        var grants = storedGrants()
        grants[bundleIdentifier] = CMUXSidebarExtensionGrant(
            manifestID: manifest.id,
            manifestDisplayName: manifest.displayName,
            apiVersion: manifest.minimumAPIVersion,
            readScopes: readScopes,
            actionScopes: actionScopes
        )
        save(grants)
    }

    private func storedGrants() -> [String: CMUXSidebarExtensionGrant] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CMUXSidebarExtensionGrant].self, from: data)) ?? [:]
    }

    private func save(_ grants: [String: CMUXSidebarExtensionGrant]) {
        if let data = try? JSONEncoder().encode(grants) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
