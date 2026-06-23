public import Foundation

/// The persistence sink a ``BrowserDataImporter`` writes parsed records into.
///
/// Parsing, decryption, de-duplication, and SQLite extraction all live inside
/// `CmuxBrowser`, but the destinations they feed (the per-profile WebKit cookie
/// store and the per-profile history store) are owned by the macOS app. This
/// protocol is the seam: the app constructs a conformer backed by its profile
/// store and injects it into the importer, so the package never references
/// `WKHTTPCookieStore` or the app's `@Observable` profile/history stores.
public protocol BrowserImportPersisting: Sendable {
    /// Writes the de-duplicated cookies into the destination profile's cookie
    /// store and returns how many were actually persisted.
    func importCookies(_ cookies: [HTTPCookie], destinationProfileID: UUID) async -> Int

    /// Merges the parsed history entries into the destination profile's history
    /// store and returns how many new entries were recorded.
    func mergeHistory(_ entries: [BrowserHistoryEntry], destinationProfileID: UUID) async -> Int
}
