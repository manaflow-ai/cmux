public import Foundation

/// Provides and wipes per-profile `WKWebsiteDataStore` instances.
///
/// Inverts the repository's dependency on WebKit. The concrete conformer in the
/// app target maps the built-in default profile to `WKWebsiteDataStore.default()`
/// and constructs `WKWebsiteDataStore(forIdentifier:)` for every other profile,
/// returning each as an opaque `AnyObject` handle the repository caches by id.
@MainActor
public protocol BrowserProfileWebsiteDataStoreProviding: AnyObject {
    /// The data store handle for the built-in default profile (`WKWebsiteDataStore.default()`).
    var defaultWebsiteDataStore: AnyObject { get }

    /// Builds an isolated data store handle for a non-default profile.
    /// - Parameter profileID: The profile's identifier, used as the store identifier.
    /// - Returns: An opaque `WKWebsiteDataStore` handle.
    func makeWebsiteDataStore(forProfileID profileID: UUID) -> AnyObject

    /// The sorted set of all website-data-type identifiers (`WKWebsiteDataStore.allWebsiteDataTypes()`).
    var allWebsiteDataTypes: [String] { get }

    /// Removes all of the given website data types from a data store handle.
    /// - Parameters:
    ///   - dataTypes: The website-data-type identifiers to remove.
    ///   - store: The opaque data store handle obtained from this provider.
    func removeAllData(ofTypes dataTypes: [String], from store: AnyObject) async
}
