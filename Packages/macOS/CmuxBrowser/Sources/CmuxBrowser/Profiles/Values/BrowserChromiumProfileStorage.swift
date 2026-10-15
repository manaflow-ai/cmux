public import Foundation

/// Where the Chromium engine keeps each browser profile's data.
///
/// Every Classic profile, the built-in default included, maps to its own
/// Chromium request context in `<root>/Profile-<UUID>`, so cookies, cache,
/// local storage and permissions never mix between profiles. The root is
/// `<Application Support>/<bundle identifier>/Chromium`; tagged dev builds
/// (`CMUX_TAG`) have their own bundle identifier, so their Chromium data
/// never mixes with another tag's or with the release app's.
///
/// Chromium requires each profile directory to be a direct child of the
/// root cache path; any other path silently becomes an off-the-record
/// profile. WebKit data (`WKWebsiteDataStore`) is untouched by this type.
public struct BrowserChromiumProfileStorage: Hashable, Sendable {
    /// The Chromium root cache path (`CefSettings.root_cache_path`).
    public let root: URL

    /// Directory-name prefix of a persistent profile store.
    public static let profileDirectoryPrefix = "Profile-"

    /// Chromium's cache directories inside a profile directory: what
    /// "Clear cache" deletes when Chromium has not opened the profile.
    public static let cacheDirectoryNames = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]

    /// Creates storage rooted at `root`.
    /// - Parameter root: The Chromium root cache path.
    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Storage for the running app.
    /// - Parameters:
    ///   - bundleIdentifier: The app's bundle identifier; tagged builds pass their tagged identifier.
    ///   - applicationSupport: The user's Application Support directory.
    /// - Returns: Storage under `<applicationSupport>/<bundleIdentifier>/Chromium`.
    public static func forApplication(bundleIdentifier: String?, applicationSupport: URL) -> BrowserChromiumProfileStorage {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundle = trimmed.isEmpty || trimmed.contains("/") || trimmed.hasPrefix(".") ? "com.cmuxterm.app" : trimmed
        return BrowserChromiumProfileStorage(
            root: applicationSupport.appendingPathComponent(bundle, isDirectory: true)
                .appendingPathComponent("Chromium", isDirectory: true)
        )
    }

    /// The persistent Chromium store of a profile.
    /// - Parameter profileID: The Classic profile id (``BrowserProfileDefinition/id``).
    /// - Returns: `<root>/Profile-<UUID>`.
    public func cachePath(forProfileID profileID: UUID) -> URL {
        root.appendingPathComponent(Self.profileDirectoryPrefix + profileID.uuidString, isDirectory: true)
    }

    /// The profile whose persistent store is `path`, or `nil` when `path` is
    /// not a direct `Profile-<UUID>` child of the root (Chromium reports an
    /// off-the-record profile by its parent's path, which is not one).
    /// - Parameter path: A filesystem path reported by Chromium.
    public func profileID(forCachePath path: String) -> UUID? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL.path == root.path else { return nil }
        let name = url.lastPathComponent
        guard name.hasPrefix(Self.profileDirectoryPrefix) else { return nil }
        let rest = name.dropFirst(Self.profileDirectoryPrefix.count)
        guard rest.count == 36, let id = UUID(uuidString: String(rest)) else { return nil }
        return id
    }

    /// cmux's remembered permission answers for a profile
    /// (``BrowserSitePermissionStore``), inside the profile's store so
    /// deleting the store deletes them.
    public func sitePermissionsFile(forProfileID profileID: UUID) -> URL {
        cachePath(forProfileID: profileID).appendingPathComponent(BrowserSitePermissionStore.fileName, isDirectory: false)
    }

    /// Chromium's log file under the root.
    public var logFile: URL { root.appendingPathComponent("cef.log", isDirectory: false) }

    /// The cache directories of a profile's store (they may not exist).
    /// - Parameter profileID: The Classic profile id.
    public func cacheDirectories(forProfileID profileID: UUID) -> [URL] {
        let profile = cachePath(forProfileID: profileID)
        return Self.cacheDirectoryNames.map { profile.appendingPathComponent($0, isDirectory: true) }
    }
}
