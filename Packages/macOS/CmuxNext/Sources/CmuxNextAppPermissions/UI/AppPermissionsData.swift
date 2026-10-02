public import CmuxNextApps
public import Foundation

/// What the surfaces show about one app (from its listing and manifest).
public nonisolated struct AppPermissionsListing: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var publisher: String
    public var version: String
    /// SF Symbol name of the app icon.
    public var symbol: String
    public var tier: AppTier
    public var required: [AppScopeRequest]
    public var optional: [AppScopeRequest]
    /// Restricted scopes the review approved for this version (Verified).
    public var reviewed: Set<String>

    public init(id: String, name: String, publisher: String, version: String, symbol: String, tier: AppTier,
                required: [AppScopeRequest], optional: [AppScopeRequest] = [], reviewed: Set<String> = []) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.version = version
        self.symbol = symbol
        self.tier = tier
        self.required = required
        self.optional = optional
        self.reviewed = reviewed
    }

    public init(manifest: AppManifest, tier: AppTier, reviewed: Set<String> = []) {
        self.init(id: manifest.id, name: manifest.name.resolved(), publisher: manifest.publisherName ?? manifest.publisher,
                  version: manifest.version, symbol: Self.symbol(manifest.icon), tier: tier,
                  required: manifest.scopes, optional: manifest.optionalScopes, reviewed: reviewed)
    }

    /// The manifest's SF Symbol; a bundled image icon shows a neutral glyph here.
    private static func symbol(_ icon: AppIcon?) -> String {
        if case .symbol(let name)? = icon { return name }
        return "square.grid.2x2"
    }

    /// The manifest's reason for `scope`.
    public func reason(for scope: String) -> String {
        (required + optional).first { $0.scope == scope }?.reason ?? ""
    }

    /// The install draft with this listing's tier defaults.
    public func installDraft(profile: AppSandboxProfile? = nil) -> AppInstallDraft {
        AppInstallDraft(appID: id, tier: tier, required: required, optional: optional, reviewed: reviewed, profile: profile)
    }
}

/// One line of the per-app activity log: an op call by scope, never params.
public nonisolated struct AppActivityEntry: Sendable, Hashable, Identifiable {
    public var id: Int
    public var op: String
    public var scope: String?
    /// `user`, `script`, `mcp`.
    public var origin: String
    public var result: AppActivityResult
    public var time: Date

    public init(id: Int, op: String, scope: String?, origin: String, result: AppActivityResult, time: Date) {
        self.id = id
        self.op = op
        self.scope = scope
        self.origin = origin
        self.result = result
        self.time = time
    }
}

public nonisolated enum AppActivityResult: String, Sendable, Hashable, Codable {
    case allowed
    case asked
    case refused
}
