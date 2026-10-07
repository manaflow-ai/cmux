public import Foundation

/// Trust tier of a listing (Lawrence 2026-10-02, app-platform.md
/// section 10): first-party (publisher cmux), Verified, unverified
/// third-party. The tier sets the default grant: first-party and Verified
/// run with their granted scopes; unverified starts sandboxed with only
/// read scopes.
public nonisolated enum AppStoreTier: String, Sendable, Hashable, CaseIterable, Codable {
    case firstParty = "first-party"
    case verified
    case unverified

    /// The tier this client can tell from the manifest alone: publisher
    /// `cmux` is first-party; anything else is unverified until the store
    /// says it is Verified.
    public static func local(_ manifest: AppManifest) -> AppStoreTier {
        manifest.publisher == "cmux" ? .firstParty : .unverified
    }
}

/// One published version of a listing.
public nonisolated struct AppStoreVersion: Sendable, Hashable, Identifiable {
    public var version: String
    public var engines: String
    public var scopes: [String]
    public var publishedAt: Date?
    public var yanked: Bool
    public var id: String { version }

    public init(version: String, engines: String, scopes: [String], publishedAt: Date? = nil, yanked: Bool = false) {
        self.version = version
        self.engines = engines
        self.scopes = scopes
        self.publishedAt = publishedAt
        self.yanked = yanked
    }
}

/// A store listing (`app.search` / `app.info` result shape). Bundled
/// listings also carry their package, so the store can preview them live.
public nonisolated struct AppStoreListing: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: AppLocalizedText
    public var description: AppLocalizedText
    public var publisherName: String
    public var publisherVerified: Bool
    public var repository: URL?
    public var icon: AppIcon?
    public var categories: [String]
    public var tier: AppStoreTier
    public var latestVersion: String
    public var installCount: Int
    public var versions: [AppStoreVersion]
    /// Requested scopes with the reason shown at consent.
    public var scopes: [AppScopeRequest]
    public var optionalScopes: [AppScopeRequest]
    /// The package, when this client has it (bundled or downloaded).
    public var bundle: AppBundle?

    public init(bundle: AppBundle, tier: AppStoreTier, installCount: Int = 0) {
        let manifest = bundle.manifest
        id = manifest.id
        name = manifest.name
        description = manifest.description
        publisherName = manifest.publisherName ?? manifest.publisher
        publisherVerified = tier == .firstParty || tier == .verified
        repository = manifest.repository
        icon = manifest.icon
        categories = manifest.categories
        self.tier = tier
        latestVersion = manifest.version
        self.installCount = installCount
        versions = [AppStoreVersion(version: manifest.version, engines: manifest.engine, scopes: manifest.scopes.map(\.scope))]
        scopes = manifest.scopes
        optionalScopes = manifest.optionalScopes
        self.bundle = bundle
    }

    /// Matches a store search: name, id, description, categories, keywords.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = ([id, name.resolved(), name.english, description.resolved(), publisherName] + categories
            + (bundle?.manifest.keywords ?? [])).joined(separator: " ").lowercased()
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}
