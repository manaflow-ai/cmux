public import Foundation

/// HTTP transport backed by `URLSession`.
public struct URLSessionIssueInboxHTTPTransport: IssueInboxHTTPTransport {
    private let session: URLSession

    /// Creates a URLSession-backed transport.
    ///
    /// - Parameter session: Session used for requests. Defaults to an ephemeral session.
    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration)
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IssueSourceError.providerMessage(provider: .github, message: "Missing HTTP response")
        }
        return (data, httpResponse)
    }
}
