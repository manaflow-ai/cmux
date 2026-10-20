public import Foundation

/// Provides per-profile history stores and the locations of their backing files.
///
/// Inverts the repository's dependency on `BrowserHistoryStore`. The concrete
/// conformer in the app target maps the built-in default profile to the shared
/// history store and constructs a file-backed store for every other profile.
@MainActor
public protocol BrowserProfileHistoryProviding: AnyObject {
    /// The shared history store used by the built-in default profile.
    var sharedHistoryStore: any BrowserProfileHistoryStore { get }

    /// Builds a file-backed history store for a non-default profile.
    /// - Parameter fileURL: The profile's history file location, or `nil` to use the store's own default.
    func makeHistoryStore(fileURL: URL?) -> any BrowserProfileHistoryStore

    /// The history file URL for the built-in default profile, if resolvable.
    func defaultHistoryFileURLForCurrentBundle() -> URL?

    /// Maps a bundle identifier to the namespace segment used in history paths.
    /// - Parameter bundleIdentifier: The running app's bundle identifier.
    /// - Returns: The normalized namespace folder name.
    func normalizedBrowserHistoryNamespace(forBundleIdentifier bundleIdentifier: String) -> String

    /// Flushes pending saves on the shared default history store.
    func flushSharedHistoryPendingSaves()
}
