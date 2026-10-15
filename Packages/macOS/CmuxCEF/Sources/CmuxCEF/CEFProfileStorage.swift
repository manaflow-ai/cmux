public import Foundation

/// Chromium storage paths, keyed by the cmux browser profile id.
///
/// `root_cache_path` is `<Application Support>/<bundle id>/Chromium`. Every
/// cmux profile, the default one included, gets its own request context in
/// `Profile-<uuid>`: Chromium 136+ refuses remote debugging on the default
/// user data dir, and it keeps extensions and cookies per profile. Chrome
/// style requires each profile directory to be a direct child of the root;
/// any other path silently becomes an off-the-record profile.
public struct CEFProfileStorage: Hashable, Sendable {
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
        let support = applicationSupport ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app"
        return CEFProfileStorage(root: support.appendingPathComponent(bundle).appendingPathComponent("Chromium"))
    }

    /// The persistent store of `profile`.
    public func cachePath(for profile: UUID) -> URL {
        root.appendingPathComponent("Profile-" + profile.uuidString)
    }

    /// Prefix of an off-the-record context key (the shim's
    /// `kOffTheRecordPrefix`): an in-memory Chromium profile, no directory.
    public static let offTheRecordPrefix = "cmux-otr:"

    /// The shim's request context key of a store: its directory for a
    /// persistent profile, an off-the-record key for an ephemeral one.
    public func contextKey(for profile: UUID, offTheRecord: Bool) -> String {
        guard offTheRecord else { return cachePath(for: profile).path }
        return Self.offTheRecordPrefix + profile.uuidString.lowercased()
    }

    /// True when `path` is a persistent cmux profile directory (a direct
    /// child `Profile-*` of the root). Chromium reports an off-the-record
    /// profile by its parent's path, which is not one.
    public func isPersistentProfilePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return url.deletingLastPathComponent().path == root.standardizedFileURL.resolvingSymlinksInPath().path
            && url.lastPathComponent.hasPrefix("Profile-")
    }

    /// The cmux profile of a persistent store directory (`Profile-<UUID>`).
    public func profile(forPath path: String) -> UUID? {
        guard isPersistentProfilePath(path) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent.dropFirst("Profile-".count)
        return UUID(uuidString: String(name.prefix(36)))
    }

    public var logFile: URL { root.appendingPathComponent("cef.log") }

    /// The previous run's `cef.log`. Chromium starts `cef.log` afresh at
    /// each launch, which would lose the FATAL line of a run that crashed.
    public var previousLogFile: URL { root.appendingPathComponent("cef.previous.log") }

    /// Moves `cef.log` to `cef.previous.log`, replacing an older one, before
    /// Chromium starts. False when there was no log to keep.
    @discardableResult
    public func keepPreviousLog() -> Bool {
        rename(logFile.path, previousLogFile.path) == 0
    }

    /// Right before Chromium starts: the root exists and the last run's log is kept.
    public func prepareForLaunch() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        keepPreviousLog()
    }
}
