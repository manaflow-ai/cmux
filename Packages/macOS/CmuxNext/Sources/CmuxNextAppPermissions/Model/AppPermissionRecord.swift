import Foundation

/// One installed app's permission state: the tier copied from the listing,
/// the reviewed restricted scopes of this version, the scopes its manifest
/// declares, the sandbox profile and the grant.
public nonisolated struct AppPermissionRecord: Sendable, Hashable, Codable {
    public var appID: String
    public var tier: AppTier
    /// Restricted scopes the human review approved for this version (Verified only).
    public var reviewed: Set<String>
    /// Required and optional scopes of the manifest; the grant never holds others.
    public var declared: Set<String>
    public var profile: AppSandboxProfile
    public var grant: AppGrant

    public init(appID: String, tier: AppTier, reviewed: Set<String> = [], declared: Set<String>,
                profile: AppSandboxProfile, grant: AppGrant) {
        self.appID = appID
        self.tier = tier
        self.reviewed = reviewed
        self.declared = declared
        self.profile = profile
        self.grant = grant
    }
}
