public import Foundation

/// Resolves where a profile's `browser_history.json` lives on disk and how the
/// per-build namespace folds debug/staging bundle identifiers together.
///
/// All filesystem inputs are injected (the Application Support directory and
/// bundle identifier), so callers at the app composition root pass the live
/// `FileManager`/`Bundle` values while tests pass fixtures. The store keeps the
/// resolved file URL; this type owns only the pure path math.
public struct BrowserHistoryLocation: Sendable {
    /// Application Support root used as the parent of the history namespace
    /// folder. Injected so tests can point at a temporary directory.
    public let applicationSupportDirectory: URL
    /// The current process bundle identifier, used to derive the namespace.
    public let bundleIdentifier: String

    /// Creates a location resolver over an explicit Application Support root and
    /// bundle identifier.
    public init(applicationSupportDirectory: URL, bundleIdentifier: String) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.bundleIdentifier = bundleIdentifier
    }

    /// Folds tagged debug/staging bundle identifiers down to a shared namespace
    /// so every dev build of the same lane reuses one history file, while
    /// production identifiers pass through unchanged.
    public static func normalizedNamespace(bundleIdentifier: String) -> String {
        if bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.") {
            return "com.cmuxterm.app.debug"
        }
        if bundleIdentifier.hasPrefix("com.cmuxterm.app.staging.") {
            return "com.cmuxterm.app.staging"
        }
        return bundleIdentifier
    }

    /// The normalized namespace for ``bundleIdentifier``.
    public var namespace: String {
        Self.normalizedNamespace(bundleIdentifier: bundleIdentifier)
    }

    /// The `browser_history.json` URL under the normalized namespace folder.
    public var historyFileURL: URL {
        let dir = applicationSupportDirectory.appendingPathComponent(namespace, isDirectory: true)
        return dir.appendingPathComponent("browser_history.json", isDirectory: false)
    }

    /// The pre-namespace (raw bundle identifier) history URL that older tagged
    /// builds wrote, or `nil` when the namespace already equals the raw
    /// identifier (so there is nothing legacy to migrate from).
    public var legacyTaggedHistoryFileURL: URL? {
        guard namespace != bundleIdentifier else { return nil }
        let dir = applicationSupportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
        return dir.appendingPathComponent("browser_history.json", isDirectory: false)
    }
}
