#if os(iOS)
import CmuxMobileShell
import Foundation
import Observation

/// App-root minimum-Mac-version state: the last fetched
/// `/api/mobile-mac-compat` list, cached per API origin, with the
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
    public typealias Loader = @Sendable (URL) async throws -> Data

    static let cacheKey = "dev.cmux.mobile.macCompat.remoteList.v1"
    static let requestPath = "/api/mobile-mac-compat"

    private let requestURL: URL?
    private let defaults: UserDefaults
    private let loader: Loader

    /// The effective policy: the last successfully decoded fetch (this
    /// launch or a cached previous one), else the compiled-in fallback.
    public private(set) var policy: MobileMacCompatPolicy

    public init(
        apiBaseURL: String?,
        defaults: UserDefaults = .standard,
        loader: Loader? = nil
    ) {
        if let apiBaseURL, !apiBaseURL.isEmpty {
            requestURL = URL(string: apiBaseURL + Self.requestPath)
        } else {
            requestURL = nil
        }
        self.defaults = defaults
        self.loader = loader ?? Self.urlSessionLoader
        let scheme = requestURL?.scheme?.lowercased() ?? "none"
        let host = requestURL?.host?.lowercased() ?? "none"
        let port = requestURL?.port.map(String.init) ?? "default"
        let environmentCacheKey = "\(Self.cacheKey).\(scheme).\(host).\(port)"
        self.environmentCacheKey = environmentCacheKey
        if let cached = defaults.data(forKey: environmentCacheKey),
           let decoded = MobileMacCompatPolicy.decode(cached) {
            policy = decoded
        } else {
            policy = .baked
        }
    }

    /// The cache key scoped to the configured API origin (scheme, host, and
    /// port), so a build that switches environments never consumes another
    /// environment's minimums from the cache.
    private let environmentCacheKey: String

    /// Fetches the remote list, replacing the device cache on success. Any
    /// failure (offline, server error, payload this build cannot fully
    /// parse) keeps the current policy.
    public func refresh() async {
        guard let requestURL else { return }
        do {
            let data = try await loader(requestURL)
            guard let decoded = MobileMacCompatPolicy.decode(data) else { return }
            policy = decoded
            defaults.set(data, forKey: environmentCacheKey)
        } catch {
            // Cache (or baked fallback) wins while offline.
        }
    }

    private static let urlSessionLoader: Loader = { url in
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
#endif
