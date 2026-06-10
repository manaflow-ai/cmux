import Foundation
import WebKit

/// Always-fresh policy for local dev servers (Next.js, Vite, etc.): when
/// enabled, reloads become hard reloads, programmatic loads skip the local
/// cache, and cached entries for dev hosts are purged before navigations.
enum BrowserDevHostCachePolicy {
    static let enabledKey = "browserDisableCacheForDevHosts"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }

    static func isDevHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        // nil rawAllowlist evaluates against the built-in defaults (localhost,
        // *.localhost, 127.0.0.1, ::1, 0.0.0.0, *.localtest.me) regardless of
        // the user's insecure-HTTP allowlist customization.
        return BrowserInsecureHTTPSettings.isHostAllowed(host, rawAllowlist: nil)
    }

    static func shouldBypassCache(for url: URL?, defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(defaults: defaults) else { return false }
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return isDevHost(url.host)
    }

    /// Removes cached entries for dev hosts only; other origins' cache is untouched.
    /// Failures are non-fatal by design — callers proceed regardless.
    @MainActor
    static func purgeDevHostCache(in store: WKWebsiteDataStore) async {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
        let records = await store.dataRecords(ofTypes: types)
        let devRecords = records.filter { isDevHost($0.displayName) }
        guard !devRecords.isEmpty else { return }
        await store.removeData(ofTypes: types, for: devRecords)
    }
}
