public import Foundation

/// Chromium storage paths, keyed by the daemon's profile id
/// (plans/cmux-next/browser.md, "Per-profile data dirs").
///
/// `root_cache_path` is `<Application Support>/<bundle id>/Chromium`. Every
/// cmux profile, the default one included, gets its own request context in
/// `Profile-<uuid>`: Chromium 136+ refuses remote debugging on the default user
/// data dir, and it keeps extensions and cookies per profile. Chrome style
/// requires each profile directory to be a direct child of the root; any
/// other path silently becomes an off-the-record profile.
public nonisolated struct CEFProfileStorage: Hashable, Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Storage for the running app. Tagged DEV builds have distinct bundle
    /// ids, so their data never mixes with release data.
    public static func forApplication(
        bundleIdentifier: String?,
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> CEFProfileStorage {
        let support = applicationSupport ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return CEFProfileStorage(root: support.appending(path: bundle).appending(path: "Chromium"))
    }

    public func cachePath(for profile: BrowserProfileID) -> URL {
        root.appending(path: "Profile-" + profile.rawValue.uuidString)
    }

    /// The remote-localhost derived store of `profile` for one machine
    /// (plans/cmux-next/remote-localhost.md section 3), a sibling of the
    /// profile directory because Chrome style needs direct children of the
    /// root. `machineKey` must be lowercase hex; anything else gets the
    /// profile's own path.
    public func cachePath(for profile: BrowserProfileID, machineKey: String?) -> URL {
        guard let machineKey, !machineKey.isEmpty, machineKey.utf8.count <= 32,
              machineKey.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return cachePath(for: profile)
        }
        return root.appending(path: "Profile-" + profile.rawValue.uuidString + "-m-" + machineKey)
    }

    /// Prefix of an off-the-record context key (the shim's
    /// `kOffTheRecordPrefix`): an in-memory Chromium profile, no directory.
    public static let offTheRecordPrefix = "cmux-otr:"

    /// The shim's request context key of a store: its directory for a
    /// persistent profile, an off-the-record key for an incognito window's
    /// profile (a remote-localhost derived store included, so it keeps its
    /// own proxy).
    public func contextKey(for profile: BrowserProfileID, machineKey: String?, offTheRecord: Bool) -> String {
        guard offTheRecord else { return cachePath(for: profile, machineKey: machineKey).path }
        var key = Self.offTheRecordPrefix + profile.rawValue.uuidString.lowercased()
        if let machineKey, cachePath(for: profile, machineKey: machineKey) != cachePath(for: profile) {
            key += "-m-" + machineKey
        }
        return key
    }

    /// True when `path` is a persistent cmux profile directory (a direct
    /// child `Profile-*` of the root). Chromium reports an off-the-record
    /// profile by its parent's path, which is not one.
    public func isPersistentProfilePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        return url.deletingLastPathComponent().path == root.standardizedFileURL.resolvingSymlinksInPath().path
            && url.lastPathComponent.hasPrefix("Profile-")
    }

    /// The cmux profile of a persistent store directory (`Profile-<UUID>`
    /// or one of its remote-localhost stores `Profile-<UUID>-m-<key>`).
    public func profile(forPath path: String) -> BrowserProfileID? {
        guard isPersistentProfilePath(path) else { return nil }
        let name = URL(filePath: path).lastPathComponent.dropFirst("Profile-".count)
        return UUID(uuidString: String(name.prefix(36))).map(BrowserProfileID.init(rawValue:))
    }

    public var logFile: URL { root.appending(path: "cef.log") }
}
