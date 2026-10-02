/// Where the App Store window gets listings: bundled now, the cloud store
/// (`app.search`, `app.info`; spec section 11) later.
public nonisolated protocol AppStoreCatalog: Sendable {
    func search(query: String, category: String?) async throws -> [AppStoreListing]
    func listing(id: String) async throws -> AppStoreListing?
}

/// The bundled first-party samples as a catalog (tier first-party).
/// Install counts are absent until the cloud store exists.
public nonisolated struct BundledAppStoreCatalog: AppStoreCatalog {
    public let listings: [AppStoreListing]

    public init(bundles: [AppBundle]) {
        listings = bundles.filter { $0.source == .bundled }.map { AppStoreListing(bundle: $0, tier: .firstParty) }
    }

    /// Scans the module's bundled samples.
    public static func scanned() -> BundledAppStoreCatalog {
        BundledAppStoreCatalog(bundles: AppBundleScanner.scan(AppPlatformResources.samples, source: .bundled).bundles)
    }

    public func search(query: String, category: String?) async throws -> [AppStoreListing] {
        listings.filter { listing in
            (category == nil || listing.categories.contains(category!)) && listing.matches(query)
        }
    }

    public func listing(id: String) async throws -> AppStoreListing? { listings.first { $0.id == id } }
}
