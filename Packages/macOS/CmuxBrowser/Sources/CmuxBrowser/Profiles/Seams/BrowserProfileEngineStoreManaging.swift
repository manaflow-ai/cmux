public import Foundation

/// A second browser engine's per-profile data store (the Chromium engine's
/// request contexts), cleared and removed together with the profile's WebKit
/// data.
///
/// The repository keeps WebKit as its own seam
/// (``BrowserProfileWebsiteDataStoreProviding``); an engine store is added at
/// runtime with ``BrowserProfileRepository/addEngineStore(_:)`` once that
/// engine is available, so a build or launch without it changes nothing.
@MainActor
public protocol BrowserProfileEngineStoreManaging: AnyObject {
    /// Short engine name reported with cleared data kinds, e.g. `"chromium"`.
    var engineName: String { get }

    /// Clears every kind of browsing data the engine keeps for a profile.
    /// - Parameter profileID: The profile id.
    /// - Returns: The data kinds cleared (e.g. `"cookies"`, `"cache"`), unprefixed.
    func clearAllData(forProfileID profileID: UUID) async -> [String]

    /// The profile was deleted: its engine data goes now when the engine has
    /// not opened it in this process, otherwise at the next launch.
    /// - Parameter profileID: The deleted profile's id.
    func profileWasDeleted(_ profileID: UUID)

    /// Writes imported cookies (browser import) into the engine's store of a
    /// profile, as the importer writes them into the profile's WebKit store.
    /// - Returns: How many cookies the engine stored.
    func importCookies(_ cookies: [HTTPCookie], intoProfileID profileID: UUID) async -> Int
}
