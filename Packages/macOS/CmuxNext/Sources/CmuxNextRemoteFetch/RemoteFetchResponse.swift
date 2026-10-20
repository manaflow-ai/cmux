public import Foundation

/// One checked HTTP response. Header names are lowercase.
public nonisolated struct RemoteFetchResponse: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    /// The final checked URL after redirects; set by ``GuardedRemoteFetch``.
    public let finalURL: URL?

    public init(status: Int, headers: [String: String], body: Data, finalURL: URL? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
}
