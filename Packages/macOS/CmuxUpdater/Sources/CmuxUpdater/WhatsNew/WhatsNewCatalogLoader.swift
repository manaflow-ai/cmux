public import Foundation

/// Fetches the highlights catalog from the website.
public struct WhatsNewCatalogLoader: Sendable {
    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = .shared, endpoint: URL = WhatsNewCatalog.endpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    /// Loads and decodes the catalog. Throws on a transport error, a non-2xx
    /// status, or an undecodable body.
    public func load() async throws -> WhatsNewCatalog {
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
