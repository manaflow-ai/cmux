#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import Observation

/// App-root minimum-Mac-version state: the last fetched
/// `/api/mobile-mac-compat` list, cached per API origin and app build, with the
/// compiled-in ``MobileMacCompatPolicy/baked`` fallback for devices that
/// have never fetched.
///
/// The policy is pushed into the shell store (which enforces it at
/// connection admission) and read by onboarding to name the minimum Mac
/// version for the running app version. A payload this build cannot fully
/// parse is discarded and the previous policy stays, so a bad remote edit
/// can never weaken or garble the constraint.
@MainActor
@Observable
public final class MobileMacCompatCenter {
    /// Fetches the payload bytes for a request URL (injectable for tests).
    public typealias Loader = @Sendable (URL) async throws -> Data

    static let cacheKey = "dev.cmux.mobile.macCompat.remoteList.v1"
    static let requestPath = "/api/mobile-mac-compat"

    private let requestURL: URL?
    private let defaults: UserDefaults
    private let loader: Loader
    private let appBuildIdentity: String

    /// The effective policy: the last successfully decoded fetch (this
    /// launch or a cached previous one), else the compiled-in fallback.
    public private(set) var policy: MobileMacCompatPolicy

    /// Creates the center for one API origin.
    ///
    /// - Parameters:
    ///   - apiBaseURL: The API origin the list is fetched from; `nil` or
    ///     empty disables fetching (the baked fallback stays).
    ///   - defaults: The store backing the per-origin payload cache.
    ///   - loader: The payload loader; `nil` uses the shared URLSession one.
    ///   - appBuildIdentity: The running iOS version/build identity used to
    ///     isolate cached policy across app upgrades. `nil` derives it from
    ///     ``AppVersionInfo/current()``; tests may provide a deterministic value.
    public init(
        apiBaseURL: String?,
        defaults: UserDefaults = .standard,
        loader: Loader? = nil,
        appBuildIdentity: String? = nil
    ) {
        let url: URL?
        if let apiBaseURL, !apiBaseURL.isEmpty {
            url = URL(string: apiBaseURL + Self.requestPath)
        } else {
            url = nil
        }
        requestURL = url
        self.defaults = defaults
        self.loader = loader ?? mobileRemoteJSONLoader
        let versionInfo = AppVersionInfo.current()
        let buildIdentity = appBuildIdentity
            ?? [versionInfo.marketingVersion, versionInfo.buildNumber, versionInfo.devTag, versionInfo.gitSHA]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        self.appBuildIdentity = buildIdentity
        let scheme = url?.scheme?.lowercased() ?? "none"
        let host = url?.host?.lowercased() ?? "none"
        let port = url?.port.map(String.init) ?? "default"
        // Version/build scoping prevents an older binary's weaker policy (or
        // its valid empty kill switch) from replacing this binary's baked
        // floor before this build has completed a successful fetch.
        let environmentCacheKey = "\(Self.cacheKey).\(scheme).\(host).\(port).\(buildIdentity)"
        self.environmentCacheKey = environmentCacheKey
        self.policy = .baked
        pruneObsoleteCacheEntries()
        if let cached = defaults.data(forKey: environmentCacheKey),
           let decoded = MobileMacCompatPolicy(decoding: cached) {
            policy = decoded
        }
    }

    /// The cache key scoped to the configured API origin (scheme, host, and
    /// port) plus this app's version/build identity, so an environment switch
    /// or app upgrade never consumes another policy from the cache.
    private let environmentCacheKey: String

    /// Keeps the UserDefaults namespace bounded as app builds and dev origins
    /// change. Only the current origin/build can be used by this process, so
    /// older entries are safe to discard before loading the current cache.
    private func pruneObsoleteCacheEntries() {
        let prefix = Self.cacheKey + "."
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(prefix) && key != environmentCacheKey {
            defaults.removeObject(forKey: key)
        }
    }

    /// Fetches the remote list, replacing the device cache on success. Any
    /// failure (offline, server error, payload this build cannot fully
    /// parse) keeps the current policy.
    public func refresh() async {
        guard let requestURL else { return }
        do {
            let data = try await loader(requestURL)
            guard let decoded = MobileMacCompatPolicy(decoding: data) else { return }
            policy = decoded
            defaults.set(data, forKey: environmentCacheKey)
        } catch {
            // Cache (or baked fallback) wins while offline.
        }
    }

}
#endif
