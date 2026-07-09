public import Foundation
public import WebKit

/// The destination sink for a browser-data import: the per-profile cookie store
/// and history merge the engine writes into.
///
/// Inverts ``BrowserDataImportService``'s dependency on the app's
/// `BrowserProfileStore`. The concrete conformer in the app target resolves the
/// profile's `WKWebsiteDataStore.httpCookieStore` and its `BrowserHistoryStore`,
/// so the engine can write imported cookies and history without the package
/// depending on the app target.
///
/// ## Isolation
///
/// `@MainActor`. Both sinks touch main-actor-isolated live state (the WebKit
/// data store and the `@MainActor` history store), exactly as the legacy
/// `BrowserDataImporter` reached them through `MainActor.run` /
/// `BrowserProfileStore.shared`. The engine itself stays off-main and hops here
/// per write, matching the original isolation boundary.
@MainActor
public protocol BrowserImportProfileDataWriting: AnyObject, Sendable {
    /// The cookie store for a destination profile.
    ///
    /// Resolved once per import entry and reused across the cookie batch, matching
    /// the legacy `BrowserProfileStore.shared.websiteDataStore(for:).httpCookieStore`.
    /// - Parameter profileID: The destination profile's identifier.
    /// - Returns: The profile's `WKHTTPCookieStore`.
    func httpCookieStore(forProfileID profileID: UUID) -> WKHTTPCookieStore

    /// Merges imported history entries into a destination profile's history store.
    ///
    /// Byte-faithful to the legacy `BrowserProfileStore.shared.historyStore(for:)
    /// .mergeImportedEntries(_:)`: returns the number of entries the store
    /// actually merged (new or updated), deduping against existing history.
    /// - Parameters:
    ///   - entries: The history records to merge.
    ///   - profileID: The destination profile's identifier.
    /// - Returns: The count of merged entries.
    func mergeImportedHistory(_ entries: [BrowserHistoryEntry], intoProfileID profileID: UUID) -> Int
}
