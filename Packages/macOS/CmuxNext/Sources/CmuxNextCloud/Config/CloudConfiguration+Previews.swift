public import Foundation

extension CloudConfiguration {
    /// Preview ingress is served directly by cmux-platform. Until production ingress is ready,
    /// only the staging and development Cloud owners have a default preview API; other builds keep their browser route.
    public func platformPreviewAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
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
}
