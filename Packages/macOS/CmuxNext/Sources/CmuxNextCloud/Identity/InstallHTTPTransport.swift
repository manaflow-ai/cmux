public import CmuxInstallAuthCore
public import Foundation

/// POSTs install-auth JSON to the API Worker at `baseURL`. Redirects are
/// refused (a bearer or a signed challenge never follows one), and nothing
/// is cached.
public struct InstallHTTPTransport: InstallAuthTransport {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = json
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func get(_ path: String, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        // The path joins the base as `post` does; a query after "?" is kept as given.
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard var components = URLComponents(url: baseURL.appendingPathComponent(String(parts[0])), resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Answers every redirect with "do not follow" (the completion-handler form:
/// the async delegate form crashes swift 6.4 SILGen in this module).
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
