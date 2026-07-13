import CCEF
import Foundation

/// A browser profile with isolated cookies, storage, and cache, backed by a
/// CEF request context whose cache lives at
/// `<rootCachePath>/Profile-<name>`. Pass nil (the default profile) to share
/// the global context.
public final class CEFProfile {
    /// The caller-supplied profile identity (not sanitized; the cache
    /// directory name is derived from it).
    public let name: String
    let contextPtr: UnsafeMutablePointer<cef_request_context_t>

    /// Requires CEFApp to be initialized. Creating the same name twice returns
    /// a context over the same on-disk profile.
    public init?(name: String) {
        guard CEFApp.shared.isInitialized, let root = CEFApp.shared.rootCachePath else { return nil }
        // Chrome-bootstrap CEF requires profile directories to be direct
        // children of root_cache_path; nesting fails with "Cannot create
        // profile at path".
        let cachePath = root.appendingPathComponent(Self.cacheDirectoryName(for: name), isDirectory: true)

        var settings = cef_request_context_settings_t()
        settings.size = numericCast(MemoryLayout<cef_request_context_settings_t>.size)
        settings.cache_path.assign(cachePath.path)
        settings.persist_session_cookies = 1
        guard let ptr = CEFRuntime.createRequestContext(&settings, nil) else { return nil }

        self.name = name
        self.contextPtr = ptr
        Self.register(self)
    }

    /// Maps a profile name to its directory name under the root cache path.
    /// Unsupported characters are replaced, and because that replacement is
    /// not injective ("Work?" and "Work!" both sanitize to "Work-"), a stable
    /// hash of the original name is appended whenever sanitization altered
    /// it — distinct profiles must never share a cache directory (and its
    /// cookies/storage). djb2, not hashValue: Swift string hashes are seeded
    /// per process and would move the directory every launch.
    static func cacheDirectoryName(for name: String) -> String {
        let sanitized = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        var directoryName = String(sanitized)
        if directoryName != name {
            var hash: UInt64 = 5381
            for byte in name.utf8 {
                hash = hash &* 33 &+ UInt64(byte)
            }
            directoryName += "-" + String(hash, radix: 16)
        }
        return "Profile-\(directoryName)"
    }

    deinit {
        invalidate()
    }

    private var invalidated = false

    /// Drops the wrapper's context reference. Live profile wrappers at
    /// cef_shutdown are a fatal CEF DCHECK, so CEFApp.shutdown invalidates
    /// every registered profile first.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        Self.liveProfiles.remove(self)
        cefRelease(UnsafeMutableRawPointer(contextPtr))
    }

    private static let liveProfiles = NSHashTable<CEFProfile>.weakObjects()

    static func register(_ profile: CEFProfile) {
        liveProfiles.add(profile)
    }

    static func invalidateAllLiveProfiles() {
        for profile in liveProfiles.allObjects {
            profile.invalidate()
        }
    }
}
