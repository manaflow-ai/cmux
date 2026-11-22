public import CMUXAuthCore
public import CmuxInstallAuthCore
public import Foundation

/// POSTs install-auth JSON to the API Worker at `baseURL`. Redirects are
/// refused (a bearer or a signed challenge never follows one), and nothing
/// is cached. A read, the challenge and a keyed op get a new socket when
/// their connection goes nowhere (``CloudConnectHedge``).
public struct InstallHTTPTransport: InstallAuthTransport {
    private let baseURL: URL
    private let session: URLSession
    /// A tagged dev build's cloud data space (``CloudConfiguration/buildSpace``); none for nightly; a misconfigured dev build's requests throw.
    private let buildSpace: CMUXBuildSpaceState

    public init(baseURL: URL, buildSpace: CMUXBuildSpaceState) {
        self.baseURL = baseURL
        self.buildSpace = buildSpace
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let (data, response) = try await CloudConnectHedge().data(for: try postRequest(path, json: json, bearer: bearer, headers: headers),
                                                                  on: session)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func get(_ path: String, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let (data, response) = try await CloudConnectHedge().data(for: getRequest(path, bearer: bearer, headers: headers), on: session)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The request ``post(_:json:bearer:headers:)`` sends.
    func postRequest(_ path: String, json: Data, bearer: String?, headers: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = json
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        try authorize(&request, bearer: bearer, headers: headers)
        return request
    }

    /// The request ``get(_:bearer:headers:)`` sends.
    func getRequest(_ path: String, bearer: String?, headers: [String: String]) throws -> URLRequest {
        // The path joins the base as `post` does; a query after "?" is kept as given.
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard var components = URLComponents(url: baseURL.appendingPathComponent(String(parts[0])), resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        try authorize(&request, bearer: bearer, headers: headers)
        return request
    }

    private func authorize(_ request: inout URLRequest, bearer: String?, headers: [String: String]) throws {
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        try buildSpace.apply(to: &request)
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
