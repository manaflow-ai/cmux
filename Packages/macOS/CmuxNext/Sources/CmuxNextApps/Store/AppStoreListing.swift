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

/// A store listing: what the Discover tab shows for one app the
/// supervisor knows (installed or not). Built from the app's record; a
/// cloud catalog (`app.search`, `app.info`) adds listings later.
public nonisolated struct AppStoreListing: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: AppLocalizedText
    public var description: AppLocalizedText
    public var publisherName: String
    public var publisherVerified: Bool
    public var repository: URL?
    public var icon: AppIcon?
    public var categories: [String]
    public var keywords: [String]
    public var tier: AppStoreTier
    public var version: String
    /// Requested scopes with the reason shown at consent.
    public var scopes: [AppScopeRequest]
    public var optionalScopes: [AppScopeRequest]
    public var implementations: [AppImplementation]
    /// Icons and scene images, when this Mac has the bundle.
    public var bundleDirectory: URL?

    public init(record: AppRecord) {
        let manifest = record.manifest
        id = record.id
        name = manifest.name
        description = manifest.description
        publisherName = manifest.publisherName ?? manifest.publisher
        publisherVerified = record.tier == .firstParty || record.tier == .verified
        repository = manifest.repository
        icon = manifest.icon
        categories = manifest.categories
        keywords = manifest.keywords
        tier = record.tier
        version = record.version
        scopes = manifest.scopes
        optionalScopes = manifest.optionalScopes
        implementations = manifest.implementations
        bundleDirectory = record.bundleDirectory
    }

    /// Matches a store search: name, id, description, publisher, categories, keywords.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = ([id, name.resolved(), name.english, description.resolved(), publisherName] + categories + keywords)
            .joined(separator: " ").lowercased()
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}
