public import Foundation

/// Fetches `/api/campaigns` with conditional revalidation.
///
/// The route is public, CDN-cached, and strongly ETagged, so the client sends
/// `If-None-Match` and treats 304 as "keep what you have". Campaigns are
/// best-effort chrome: every failure is reported as `.unavailable` and the
/// caller keeps its cached catalog.
public struct CampaignCatalogClient: Sendable {
    public enum FetchResult: Sendable {
        case fresh(catalog: CampaignCatalog, rawData: Data, etag: String?)
        case notModified
        case unavailable
    }

    private let apiBaseURL: String
    private let session: URLSession

    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL, no trailing slash.
    ///   - session: Injected in tests; production uses a short-timeout
    ///     ephemeral session so a stalled fetch cannot pin a refresh.
    public init(apiBaseURL: String, session: URLSession? = nil) {
        self.apiBaseURL = apiBaseURL
        self.session = session ?? Self.defaultSession()
    }

    public func fetch(etag: String?) async -> FetchResult {
        guard let url = URL(string: apiBaseURL + "/api/campaigns") else { return .unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unavailable }
        switch http.statusCode {
        case 304:
            return .notModified
        case 200:
            guard let catalog = try? CampaignCatalog.decode(from: data) else { return .unavailable }
            return .fresh(
                catalog: catalog,
                rawData: data,
                etag: http.value(forHTTPHeaderField: "ETag")
            )
        default:
            return .unavailable
        }
    }

    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }
}
