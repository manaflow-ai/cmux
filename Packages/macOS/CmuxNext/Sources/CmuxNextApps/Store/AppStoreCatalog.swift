/// Where the App Store window gets listings: bundled now, the cloud store
/// (`app.search`, `app.info`; spec section 11) later.
public nonisolated protocol AppStoreCatalog: Sendable {
    func search(query: String, category: String?) async throws -> [AppStoreListing]
    func listing(id: String) async throws -> AppStoreListing?
}

/// The apps shipped inside cmux (first-party apps and samples) as a catalog
/// (tier first-party). Built from the registry's scan, never from disk here:
/// the store opens on the main actor and must not do I/O (architecture 5a).
/// Install counts are absent until the cloud store exists.
public nonisolated struct BundledAppStoreCatalog: AppStoreCatalog {
    public let listings: [AppStoreListing]

    /// The App Store itself is an app but never lists itself.
    public static let selfID = "cmux/app-store"

    public init(bundles: [AppBundle]) {
        listings = bundles.filter { $0.source != .local && $0.id != Self.selfID }.map { AppStoreListing(bundle: $0, tier: .firstParty) }
    }


    public func search(query: String, category: String?) async throws -> [AppStoreListing] {
        listings.filter { listing in
            (category == nil || listing.categories.contains(category!)) && listing.matches(query)
        }
    }

    public func listing(id: String) async throws -> AppStoreListing? { listings.first { $0.id == id } }
}

/// The bundled catalog over the registry's current scan: reads the bundles
/// the registry already loaded off the main actor, so opening the store does
/// no disk I/O. Empty until the first scan finishes; the owner refreshes the
/// store model after `AppRegistry.load()`.
public nonisolated struct RegistryAppStoreCatalog: AppStoreCatalog {
    private let bundles: @Sendable () async -> [AppBundle]

    public init(bundles: @escaping @Sendable () async -> [AppBundle]) {
        self.bundles = bundles
    }

    @MainActor public init(registry: AppRegistry) {
        self.init { [weak registry] in await MainActor.run { registry?.apps.map(\.bundle) ?? [] } }
    }

    public func search(query: String, category: String?) async throws -> [AppStoreListing] {
        try await BundledAppStoreCatalog(bundles: bundles()).search(query: query, category: category)
    }

    public func listing(id: String) async throws -> AppStoreListing? {
        try await BundledAppStoreCatalog(bundles: bundles()).listing(id: id)
    }
}
