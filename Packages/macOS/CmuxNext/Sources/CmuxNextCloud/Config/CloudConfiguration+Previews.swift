public import Foundation

extension CloudConfiguration {
    /// Preview ingress is served directly by cmux-platform. Until production ingress is ready,
    /// only the staging and development Cloud owners have a default preview API; other builds keep their browser route.
    public func platformPreviewAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let runtimeSelection { return runtimeSelection.platformOrigin }
        guard linkSource == .appServer, isDebugBuild, !isProductionAuth else { return nil }
        if let raw = environment["CMUX_NEXT_PLATFORM_PREVIEW_API_URL"] {
            guard let url = URL(string: raw), url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { return nil }
            return url
        }
        // Each Cloud owner's previews come from its own environment's cmux-platform.
        switch ownerAPIBaseURL(environment: environment).host {
        case "cloud-api-staging.cmux.dev": return URL(string: "https://cmux-platform-staging.debussy.workers.dev")
        case Self.developmentWorkerOrigin.host: return URL(string: "https://cmux-platform-development.debussy.workers.dev")
        default: return nil
        }
    }

    /// The cmux-platform origin used by the Artifacts page. Release builds always use the
    /// production Worker; debug builds may point at a local or preview deployment explicitly.
    public func artifactsAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let runtimeSelection { return runtimeSelection.platformOrigin }
        if isDebugBuild, let raw = environment["CMUX_NEXT_ARTIFACTS_API_URL"],
           let url = URL(string: raw), Self.isPlatformOrigin(url) {
            return url
        }
        if isProductionAuth {
            return URL(string: "https://cmux-platform.debussy.workers.dev")
        }
        return platformPreviewAPIBaseURL(environment: environment)
            ?? URL(string: "https://cmux-platform-development.debussy.workers.dev")
    }

    private static func isPlatformOrigin(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        switch url.scheme?.lowercased() {
        case "https": return host.hasSuffix(".debussy.workers.dev") && url.port == nil
        case "http": return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default: return false
        }
    }
}
