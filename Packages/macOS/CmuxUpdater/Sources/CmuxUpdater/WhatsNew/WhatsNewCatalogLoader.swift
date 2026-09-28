public import Foundation

/// Fetches the highlights catalog from the website.
public struct WhatsNewCatalogLoader: Sendable {
    private let session: URLSession
    private let endpoint: URL

    /// Creates a loader for `endpoint` over `session`.
    public init(session: URLSession = .shared, endpoint: URL = WhatsNewCatalog.endpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    /// Loads and decodes the catalog. Throws on a transport error, a non-2xx
    /// status, or an undecodable body.
    /// Runs off the caller's actor, so the fetch and decode never block the
    /// main actor that asks for it.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public nonisolated func load() async throws -> WhatsNewCatalog {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try WhatsNewCatalog.decode(data)
    }
}
